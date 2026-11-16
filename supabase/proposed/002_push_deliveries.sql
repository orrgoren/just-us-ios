-- Applied live at 20261115092359. Do not re-apply.
-- This file is not a migration. scripts/sql-lifecycle.sh runs it in CI.
--
-- Live send-push is v6, deployed on 2026-11-16 with the content of 5013075
-- (the same content as 7872d1e) and verify_jwt on. a12f1d1 is v3 and is the
-- rollback source.
-- supabase/proposed/functions/send-push/index.ts reads this table to enforce
-- the daily-cap, six-hour dedupe, and invite-nudge rules from
-- JustUs/Domain/PushPolicy.swift. Quiet hours are not one of those rules.
-- There is no client policy: the service role
-- is the only writer, and the iOS app cannot insert or read these rows.

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
