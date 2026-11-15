-- PROPOSED ONLY. Do not apply until Tom verifies.
-- This file is not a migration. scripts/sql-lifecycle.sh runs it in CI.
--
-- claim_push_delivery is the atomic cap and dedupe. send-push calls it with
-- the service role after it has already checked the night, the mood, and the
-- invite. The insert and the re-check share one advisory lock, so two
-- requests cannot both pass.
--
-- push_outbox holds a quiet-hours send until not_before. The edge function
-- accepts a service-role body { "kind": "flush" } and sends due rows.
-- claim_due_outbox locks the oldest due rows with FOR UPDATE SKIP LOCKED,
-- counts the attempt, and leases them for 15 minutes so a second flush
-- cannot take the same rows. A row is deleted on a final decision, sent
-- or held. It stays only when the send throws or APNs asks for a retry,
-- and only until attempts reaches the cap. A quiet-hours defer moves
-- not_before on that same row. Nothing here schedules that call.
-- pg_cron is not enabled by this file. A later apply can add, outside this
-- proposal:
--   select cron.schedule('justus-push-flush', '*/15 * * * *', $$select net.http_post(...)$$);
-- Do not install that until the function is redeployed.

alter table public.device_tokens
  add column if not exists environment text not null default 'production'
  check (environment in ('sandbox', 'production'));

create table if not exists public.push_outbox (
  id uuid primary key default gen_random_uuid(),
  caller_user_id uuid not null references auth.users (id) on delete cascade,
  recipient_user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (
    kind in ('partnerMood', 'planReady', 'inviteAccepted', 'weeklyReminder', 'inviteNudge')
  ),
  not_before timestamptz not null,
  attempts integer not null default 0,
  created_at timestamptz not null default now()
);

alter table public.push_outbox enable row level security;
revoke all on table public.push_outbox from public, anon, authenticated;
grant all on table public.push_outbox to service_role;

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
begin
  if p_kind not in ('partnerMood', 'planReady', 'inviteAccepted', 'weeklyReminder', 'inviteNudge') then
    raise exception 'kind';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_recipient::text, 0));
  begin
    v_today := (now() at time zone p_timezone)::date;
  exception
    when others then
      raise exception 'invalid_timezone';
  end;
  if exists (
    select 1 from public.push_deliveries
    where recipient_user_id = p_recipient
      and kind = p_kind
      and sent_at > now() - interval '6 hours'
  ) then
    raise exception 'deduped_6h';
  end if;
  if exists (
    select 1 from public.push_deliveries
    where recipient_user_id = p_recipient
      and transactional = false
      and (sent_at at time zone p_timezone)::date = v_today
  ) then
    raise exception 'daily_non_transactional';
  end if;
  insert into public.push_deliveries (recipient_user_id, kind, transactional)
  values (p_recipient, p_kind, false)
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.claim_push_delivery(uuid, text, text) from public, anon, authenticated;
grant execute on function public.claim_push_delivery(uuid, text, text) to service_role;

-- One flush at a time per row. The lease moves not_before forward inside
-- the same statement as the lock, so the lock does not have to outlive
-- the request. The returned not_before is the time the row was due.
create or replace function public.claim_due_outbox(p_limit integer)
returns table (
  id uuid,
  caller_user_id uuid,
  kind text,
  attempts integer,
  not_before timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(auth.role(), '') is distinct from 'service_role' then
    raise exception 'forbidden';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 50 then
    raise exception 'bad_limit';
  end if;
  return query
  with due as (
    select queued.id, queued.not_before
    from public.push_outbox as queued
    where queued.not_before <= now()
    order by queued.not_before, queued.id
    limit p_limit
    for update skip locked
  )
  update public.push_outbox as outbox
  set attempts = outbox.attempts + 1,
      not_before = now() + interval '15 minutes'
  from due
  where outbox.id = due.id
  returning outbox.id, outbox.caller_user_id, outbox.kind, outbox.attempts, due.not_before;
end;
$$;

revoke all on function public.claim_due_outbox(integer) from public, anon, authenticated;
grant execute on function public.claim_due_outbox(integer) to service_role;
