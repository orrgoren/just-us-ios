-- NOT APPLIED. Apply this live once, after 016. Do not re-apply.
-- 016 is applied live on 2026-11-16 as 20261116050321.
-- scripts/sql-lifecycle.sh runs this against a throwaway database only.
--
-- A sender key that rotates out stays in device_keys with retired_at set,
-- so an old message still names a key the couple can see. At most 3 keys
-- per user have retired_at null. Sign-out sets retired_at on that phone's
-- row and cannot change anything else. Leave and delete_my_account still
-- delete the rows. New envelopes go only to keys that are not retired.
--
-- The chat rate limit takes an advisory lock on the sender before it
-- counts. claim_push_delivery takes its existing recipient lock and then
-- checks the 60-second chat window in that same transaction.

alter table public.device_keys
  add column if not exists retired_at timestamptz;

create or replace function app_private.guard_device_key()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or new.user_id is distinct from auth.uid() then
    raise exception 'not_authenticated';
  end if;
  if app_private.is_chat_public_key(new.public_key) = false then
    raise exception 'bad_key';
  end if;
  new.created_at := now();
  new.retired_at := null;
  return new;
end;
$$;

create or replace function app_private.guard_device_key_retire()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or old.user_id is distinct from auth.uid() then
    raise exception 'not_authenticated';
  end if;
  if new.id is distinct from old.id
     or new.user_id is distinct from old.user_id
     or new.public_key is distinct from old.public_key
     or new.created_at is distinct from old.created_at then
    raise exception 'not_editable';
  end if;
  if old.retired_at is not null then
    return old;
  end if;
  new.retired_at := now();
  return new;
end;
$$;

create or replace function app_private.cap_device_keys()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.device_keys
  set retired_at = now()
  where user_id = new.user_id
    and retired_at is null
    and id in (
      select id
      from public.device_keys
      where user_id = new.user_id
        and retired_at is null
      order by created_at desc, id desc
      offset 3
    );
  return null;
end;
$$;

create or replace function app_private.guard_chat_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  recent int;
begin
  if auth.uid() is null or new.sender_user_id is distinct from auth.uid() then
    raise exception 'not_authenticated';
  end if;
  if app_private.is_chat_public_key(new.sender_public_key) = false then
    raise exception 'bad_key';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(new.sender_user_id::text, 0));
  if not exists (
    select 1
    from public.device_keys
    where user_id = new.sender_user_id
      and public_key = new.sender_public_key
      and retired_at is null
  ) then
    raise exception 'unknown_sender_key';
  end if;
  select count(*) into recent
  from public.chat_messages
  where sender_user_id = new.sender_user_id
    and created_at > now() - interval '1 minute';
  if recent >= 30 then
    raise exception 'chat_rate';
  end if;
  new.created_at := now();
  return new;
end;
$$;

create or replace function public.claim_push_delivery(
  p_recipient uuid,
  p_kind text,
  p_timezone text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_today date;
  v_transactional boolean := p_kind = 'chatMessage';
begin
  if p_kind not in ('partnerMood', 'planReady', 'inviteAccepted', 'weeklyReminder', 'inviteNudge', 'chatMessage') then
    raise exception 'kind';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_recipient::text, 0));
  begin
    v_today := (now() at time zone p_timezone)::date;
  exception
    when others then
      raise exception 'invalid_timezone';
  end;
  if p_kind = 'chatMessage' and exists (
    select 1
    from public.push_deliveries
    where recipient_user_id = p_recipient
      and kind = 'chatMessage'
      and sent_at > now() - interval '60 seconds'
  ) then
    raise exception 'coalesced';
  end if;
  if v_transactional = false and exists (
    select 1 from public.push_deliveries
    where recipient_user_id = p_recipient
      and kind = p_kind
      and sent_at > now() - interval '6 hours'
  ) then
    raise exception 'deduped_6h';
  end if;
  if v_transactional = false and exists (
    select 1 from public.push_deliveries
    where recipient_user_id = p_recipient
      and transactional = false
      and (sent_at at time zone p_timezone)::date = v_today
  ) then
    raise exception 'daily_non_transactional';
  end if;
  insert into public.push_deliveries (recipient_user_id, kind, transactional)
  values (p_recipient, p_kind, v_transactional)
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.claim_push_delivery(uuid, text, text) from public, anon, authenticated;
grant execute on function public.claim_push_delivery(uuid, text, text) to service_role;

drop trigger if exists device_keys_retire on public.device_keys;
create trigger device_keys_retire
before update on public.device_keys
for each row
execute function app_private.guard_device_key_retire();

grant update (retired_at) on public.device_keys to authenticated;

drop policy if exists device_keys_retire on public.device_keys;
create policy device_keys_retire on public.device_keys
for update to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());
