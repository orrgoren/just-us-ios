-- PROPOSED ONLY. Do not apply until Tom verifies.
-- This file is not a migration and CI never runs it.
--
-- send-push v1 is already deployed. The replacement in
-- supabase/proposed/functions/send-push/index.ts reads this table to enforce
-- the quiet-hours, daily-cap, six-hour dedupe, and invite-nudge rules from
-- JustUs/Domain/PushPolicy.swift. Do not redeploy the function until this
-- table exists. There is no client policy: the service role is the only
-- writer, and the iOS app cannot insert or read these rows.

create table if not exists public.push_deliveries (
  id uuid primary key default gen_random_uuid(),
  recipient_user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (
    kind in ('partnerMood', 'planReady', 'inviteAccepted', 'weeklyReminder', 'inviteNudge')
  ),
  transactional boolean not null,
  sent_at timestamptz not null default now()
);

create index if not exists push_deliveries_recipient_sent
  on public.push_deliveries (recipient_user_id, sent_at desc);

alter table public.push_deliveries enable row level security;

revoke all on table public.push_deliveries from public, anon, authenticated;
grant all on table public.push_deliveries to service_role;
