-- NOT APPLIED. Apply this live once, after 015 and 015b. Do not re-apply.
-- scripts/sql-lifecycle.sh runs it against a throwaway database only.
--
-- Hardens partner chat on top of the applied 015 schema:
-- * sender_public_key must already be in device_keys for auth.uid()
-- * a public key is base64 of exactly 32 bytes
-- * created_at stays default now(), and a trigger overwrites any client value
-- * at most 30 messages per sender per minute
-- * at most 3 device keys per user; inserting another drops the oldest
-- * leaving the couple (close_couple deletes couple_members) drops device keys
-- * delete_my_account deletes device_keys explicitly, including a person
--   who has no membership row left
-- * envelopes stay at most 8 (3 of the sender's keys, 3 of the partner's,
--   and 2 spare) and the payload cap is 64 KiB of UTF-8 text
--
-- Unsend stays: chat_messages_delete still lets the sender delete their own row.
-- claim_push_delivery still treats chatMessage as transactional, so the daily
-- cap and the six-hour dedupe do not apply. The one-per-minute coalesce is
-- in send-push, not in this claim.

create or replace function app_private.is_chat_public_key(p_key text)
returns boolean
language plpgsql
immutable
as $$
declare
  raw bytea;
begin
  if p_key is null then
    return false;
  end if;
  begin
    raw := decode(p_key, 'base64');
  exception
    when others then
      return false;
  end;
  return octet_length(raw) = 32
    and encode(raw, 'base64') = p_key;
end;
$$;

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
  delete from public.device_keys
  where user_id = new.user_id
    and id in (
      select id
      from public.device_keys
      where user_id = new.user_id
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
  if not exists (
    select 1
    from public.device_keys
    where user_id = new.sender_user_id
      and public_key = new.sender_public_key
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

create or replace function app_private.drop_device_keys_for_member()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.device_keys where user_id = old.user_id;
  return old;
end;
$$;

drop trigger if exists device_keys_guard on public.device_keys;
create trigger device_keys_guard
before insert on public.device_keys
for each row
execute function app_private.guard_device_key();

drop trigger if exists device_keys_cap on public.device_keys;
create trigger device_keys_cap
after insert on public.device_keys
for each row
execute function app_private.cap_device_keys();

drop trigger if exists chat_messages_guard on public.chat_messages;
create trigger chat_messages_guard
before insert on public.chat_messages
for each row
execute function app_private.guard_chat_message();

drop trigger if exists couple_members_drop_device_keys on public.couple_members;
create trigger couple_members_drop_device_keys
after delete on public.couple_members
for each row
execute function app_private.drop_device_keys_for_member();

alter table public.device_keys drop constraint if exists device_keys_public_key_check;
alter table public.device_keys
  add constraint device_keys_public_key_check
  check (app_private.is_chat_public_key(public_key));

alter table public.chat_messages drop constraint if exists chat_messages_sender_public_key_check;
alter table public.chat_messages
  add constraint chat_messages_sender_public_key_check
  check (app_private.is_chat_public_key(sender_public_key));

do $$
declare
  constraint_name text;
begin
  select con.conname into constraint_name
  from pg_constraint con
  join pg_class rel on rel.oid = con.conrelid
  join pg_namespace nsp on nsp.oid = rel.relnamespace
  where nsp.nspname = 'public'
    and rel.relname = 'chat_messages'
    and con.contype = 'c'
    and pg_get_constraintdef(con.oid) ilike '%12000%';
  if constraint_name is not null then
    execute format('alter table public.chat_messages drop constraint %I', constraint_name);
  end if;
end $$;

alter table public.chat_messages drop constraint if exists chat_messages_envelopes_check;
alter table public.chat_messages
  add constraint chat_messages_envelopes_check
  check (
    jsonb_typeof(envelopes) = 'array'
    and jsonb_array_length(envelopes) between 1 and 8
    and octet_length(envelopes::text) <= 65536
  );

create index if not exists chat_messages_sender_created
  on public.chat_messages (sender_user_id, created_at);

-- Same body as 004, plus the device_keys delete before the login is removed.
create or replace function public.delete_my_account()
returns setof uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_couple uuid;
  v_closed uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  for v_couple in
    select touched.id
    from app_private.couples_touched_by(v_uid) as touched(id)
    order by touched.id
  loop
    v_closed := app_private.close_couple(v_couple, v_uid);
    if v_closed is not null then
      return next v_closed;
    end if;
  end loop;

  delete from public.mood_votes where user_id = v_uid;
  delete from public.memory_notes where author_user_id = v_uid;
  delete from public.private_date_plans
  where date_id in (select id from public.dates where planner_user_id = v_uid);
  delete from public.dates where planner_user_id = v_uid;
  delete from public.couple_invites
  where created_by = v_uid or redeemed_by = v_uid;
  delete from public.couple_members where user_id = v_uid;
  delete from public.couples where created_by = v_uid;
  delete from public.device_keys where user_id = v_uid;

  delete from auth.users where id = v_uid;
end;
$$;

revoke all on function public.delete_my_account() from public, anon, authenticated;
grant execute on function public.delete_my_account() to authenticated;
