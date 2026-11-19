-- Applied live on 2026-11-16 as migration partner_chat. Do not re-apply.
-- Numbered 015 because 013 and 014 are already claimed by other pull requests.
-- chat_messages was not in supabase_realtime. That step is the separate
-- live migration chat_messages_realtime, recorded in
-- 015b_chat_messages_realtime.sql. Do not re-apply that either.
--
-- A chat is ciphertext only. Each phone keeps a Curve25519 private key in
-- the Keychain and publishes the public key. A message is one sealed box
-- per device key, including the sender's own key so that phone can read
-- what it sent. There is no plaintext column.
--
-- chatMessage is a transactional push. claim_push_delivery skips the daily
-- cap and the six-hour dedupe for that kind, and records transactional true.
-- Other kinds keep the live rules. The push body is fixed in send-push and
-- must not include the message. Live send-push is v6, deployed on 2026-11-16
-- from 5013075. a12f1d1 is v3 and is the rollback source. chatMessage is
-- added on top of that v6 source and is deployed from main after this
-- branch merges.

do $$
declare
  constraint_name text;
begin
  select con.conname into constraint_name
  from pg_constraint con
  join pg_class rel on rel.oid = con.conrelid
  join pg_namespace nsp on nsp.oid = rel.relnamespace
  where nsp.nspname = 'public'
    and rel.relname = 'push_deliveries'
    and con.contype = 'c'
    and pg_get_constraintdef(con.oid) ilike '%partnerMood%';
  if constraint_name is not null then
    execute format('alter table public.push_deliveries drop constraint %I', constraint_name);
  end if;

  select con.conname into constraint_name
  from pg_constraint con
  join pg_class rel on rel.oid = con.conrelid
  join pg_namespace nsp on nsp.oid = rel.relnamespace
  where nsp.nspname = 'public'
    and rel.relname = 'push_outbox'
    and con.contype = 'c'
    and pg_get_constraintdef(con.oid) ilike '%partnerMood%';
  if constraint_name is not null then
    execute format('alter table public.push_outbox drop constraint %I', constraint_name);
  end if;
end $$;

alter table public.push_deliveries
  add constraint push_deliveries_kind_check
  check (kind in ('partnerMood', 'planReady', 'inviteAccepted', 'weeklyReminder', 'inviteNudge', 'chatMessage'));

alter table public.push_outbox
  add constraint push_outbox_kind_check
  check (kind in ('partnerMood', 'planReady', 'inviteAccepted', 'weeklyReminder', 'inviteNudge', 'chatMessage'));

create table if not exists public.device_keys (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  public_key text not null check (char_length(public_key) between 40 and 64),
  created_at timestamptz not null default now(),
  unique (user_id, public_key)
);

create table if not exists public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  couple_id uuid not null references public.couples (id) on delete cascade,
  sender_user_id uuid not null references auth.users (id),
  sender_public_key text not null check (char_length(sender_public_key) between 40 and 64),
  created_at timestamptz not null default now(),
  envelopes jsonb not null check (
    jsonb_typeof(envelopes) = 'array'
    and jsonb_array_length(envelopes) between 1 and 8
    and char_length(envelopes::text) <= 12000
  )
);

create index if not exists chat_messages_couple_created
  on public.chat_messages (couple_id, created_at);

alter table public.device_keys enable row level security;
alter table public.chat_messages enable row level security;

revoke all on table public.device_keys from public, anon;
revoke all on table public.chat_messages from public, anon;
grant select, insert, delete on public.device_keys to authenticated;
grant select, insert, delete on public.chat_messages to authenticated;

drop policy if exists device_keys_select on public.device_keys;
drop policy if exists device_keys_insert on public.device_keys;
drop policy if exists device_keys_delete on public.device_keys;
drop policy if exists chat_messages_select on public.chat_messages;
drop policy if exists chat_messages_insert on public.chat_messages;
drop policy if exists chat_messages_delete on public.chat_messages;

create policy device_keys_select on public.device_keys
for select to authenticated
using (
  user_id = auth.uid()
  or exists (
    select 1
    from public.couple_members as mine
    join public.couple_members as theirs on theirs.couple_id = mine.couple_id
    where mine.user_id = auth.uid()
      and theirs.user_id = device_keys.user_id
  )
);

create policy device_keys_insert on public.device_keys
for insert to authenticated
with check (user_id = auth.uid());

create policy device_keys_delete on public.device_keys
for delete to authenticated
using (user_id = auth.uid());

create policy chat_messages_select on public.chat_messages
for select to authenticated
using (public.is_couple_member(couple_id));

create policy chat_messages_insert on public.chat_messages
for insert to authenticated
with check (
  sender_user_id = auth.uid()
  and public.is_couple_member(couple_id)
);

create policy chat_messages_delete on public.chat_messages
for delete to authenticated
using (
  sender_user_id = auth.uid()
  and public.is_couple_member(couple_id)
);

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
