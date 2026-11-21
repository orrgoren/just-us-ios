#!/bin/bash
# Isolated Postgres check for the proposed account SQL. Never uses the live project.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if ! command -v psql >/dev/null 2>&1; then
  echo "psql is not installed" >&2
  exit 1
fi

db="justus_sql_test"
if command -v sudo >/dev/null 2>&1 && id postgres >/dev/null 2>&1; then
  sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS ${db};"
  sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${db};"
  run() { sudo -u postgres psql -d "$db" -v ON_ERROR_STOP=1 "$@"; }
else
  dropdb --if-exists "$db"
  createdb "$db"
  run() { psql -d "$db" -v ON_ERROR_STOP=1 "$@"; }
fi

run -f scripts/sql/harness.sql
# The live guards are already on the project. The throwaway database needs
# the same bodies so the triggers in lifecycle.sql exist. 003 replaces the
# date guard and leave_couple. Live order after that is 004, then the push
# files 002, 006, and 007. 007 skips itself when cron, net, or the vault
# secrets are missing.
run -f supabase/proposed/live/guard_date_update.sql
run -f supabase/proposed/live/touch_memory.sql
run -f supabase/proposed/live/guard_couple_update.sql
run -f supabase/proposed/live/guard_invite_update.sql
run -f supabase/proposed/live/leave_couple.sql
run -f supabase/proposed/003_memory_photo_and_close.sql
run -f supabase/proposed/004_delete_my_account.sql
run -f supabase/proposed/002_push_deliveries.sql
run -f supabase/proposed/006_push_claim_and_outbox.sql
run -f supabase/proposed/007_push_flush_schedule.sql
run -f supabase/proposed/012_scheduled_hint_notes.sql
run -f supabase/proposed/013_mood_until_reveal.sql
run -f supabase/proposed/live/touch_mood.sql
run -f supabase/proposed/014_mood_update_using.sql
run -f supabase/proposed/017_planner_turn.sql
run -f supabase/proposed/015_partner_chat.sql
run -c "do \$\$ begin if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then execute 'create publication supabase_realtime'; end if; end \$\$;"
run -f supabase/proposed/015b_chat_messages_realtime.sql
run -f supabase/proposed/016_chat_hardening.sql
run -f supabase/proposed/018_chat_key_retire.sql
run -f supabase/proposed/019_mood_push_cap.sql
run -f supabase/proposed/020_skip_keeps_planner.sql
run -v ON_ERROR_STOP=1 -c "
insert into auth.users (id) values ('10101010-1010-4010-8010-101010101010');
insert into public.push_outbox (id, caller_user_id, recipient_user_id, kind, not_before) values
  ('20202020-2020-4020-8020-202020202020', '10101010-1010-4010-8010-101010101010', '10101010-1010-4010-8010-101010101010', 'planReady', now() - interval '2 hours'),
  ('30303030-3030-4030-8030-303030303030', '10101010-1010-4010-8010-101010101010', '10101010-1010-4010-8010-101010101010', 'partnerMood', now() - interval '1 hour'),
  ('40404040-4040-4040-8040-404040404040', '10101010-1010-4010-8010-101010101010', '10101010-1010-4010-8010-101010101010', 'weeklyReminder', now() + interval '2 hours');
select set_config('request.jwt.claims', '{\"role\":\"service_role\"}', false);
do \$\$
declare
  def text := pg_get_functiondef('public.claim_due_outbox(integer)'::regprocedure);
begin
  if position('skip locked' in lower(def)) = 0 then
    raise exception 'claim_due_missing_skip_locked';
  end if;
  if position('order by' in lower(def)) = 0 then
    raise exception 'claim_due_missing_order';
  end if;
end \$\$;
create temp table claimed_outbox as
select * from public.claim_due_outbox(50);
do \$\$
begin
  if (select count(*) from claimed_outbox) <> 2 then
    raise exception 'claim_due_count';
  end if;
  if (
    select id from claimed_outbox order by not_before, id limit 1
  ) is distinct from '20202020-2020-4020-8020-202020202020'::uuid then
    raise exception 'claim_due_order';
  end if;
  if exists (select 1 from claimed_outbox where id = '40404040-4040-4040-8040-404040404040') then
    raise exception 'future_row_claimed';
  end if;
  if exists (
    select 1 from public.push_outbox
    where id = '20202020-2020-4020-8020-202020202020' and attempts <> 1
  ) then
    raise exception 'attempt_not_counted';
  end if;
  if exists (
    select 1 from public.push_outbox
    where id = '20202020-2020-4020-8020-202020202020' and not_before <= now()
  ) then
    raise exception 'lease_did_not_move';
  end if;
  if exists (select 1 from public.claim_due_outbox(50) where id <> '40404040-4040-4040-8040-404040404040') then
    raise exception 'second_flush_took_a_leased_row';
  end if;
  if exists (select 1 from public.claim_due_outbox(50)) then
    raise exception 'second_flush_took_the_future_row';
  end if;
end \$\$;
select set_config('request.jwt.claims', '{\"role\":\"authenticated\"}', false);
do \$\$
begin
  perform public.claim_due_outbox(50);
  raise exception 'authenticated_claimed_outbox';
exception
  when others then
    if sqlerrm <> 'forbidden' then
      raise;
    end if;
end \$\$;
delete from public.push_outbox where caller_user_id = '10101010-1010-4010-8010-101010101010';
delete from auth.users where id = '10101010-1010-4010-8010-101010101010';
"
run -f scripts/sql/lifecycle.sql

# Two account deletes at once. The first transaction holds the couple row
# lock across pg_sleep. The second waits, then deletes the remaining login.
run -v ON_ERROR_STOP=1 -c "
insert into auth.users (id) values
  ('abababab-abab-4aba-8aba-abababababab'),
  ('cdcdcdcd-cdcd-4cdc-8cdc-cdcdcdcdcdcd');
insert into public.couples (id, created_by, weekday, local_time, timezone, default_duration_minutes, invitee_display_name) values
  ('abab1111-abab-4aba-8aba-abababababab', 'abababab-abab-4aba-8aba-abababababab', 4, '20:30', 'Asia/Jerusalem', 90, 'Dee');
insert into public.couple_members (couple_id, user_id, display_name, member_index) values
  ('abab1111-abab-4aba-8aba-abababababab', 'abababab-abab-4aba-8aba-abababababab', 'Abe', 0),
  ('abab1111-abab-4aba-8aba-abababababab', 'cdcdcdcd-cdcd-4cdc-8cdc-cdcdcdcdcdcd', 'Dee', 1);
"
if command -v sudo >/dev/null 2>&1 && id postgres >/dev/null 2>&1; then
  psql_cmd=(sudo -u postgres psql -d "$db" -v ON_ERROR_STOP=1)
else
  psql_cmd=(psql -d "$db" -v ON_ERROR_STOP=1)
fi
"${psql_cmd[@]}" -c "
  begin;
  select set_config('request.jwt.claim.sub', 'abababab-abab-4aba-8aba-abababababab', false);
  select public.delete_my_account();
  select pg_sleep(2);
  commit;
" &
first_pid=$!
sleep 0.4
"${psql_cmd[@]}" -c "
  begin;
  select set_config('request.jwt.claim.sub', 'cdcdcdcd-cdcd-4cdc-8cdc-cdcdcdcdcdcd', false);
  select public.delete_my_account();
  commit;
"
wait "$first_pid"
run -v ON_ERROR_STOP=1 -c "
do \$\$
begin
  if exists (
    select 1 from auth.users
    where id in (
      'abababab-abab-4aba-8aba-abababababab',
      'cdcdcdcd-cdcd-4cdc-8cdc-cdcdcdcdcdcd'
    )
  ) then
    raise exception 'one_delete_lost';
  end if;
  if exists (select 1 from public.couples where id = 'abab1111-abab-4aba-8aba-abababababab') then
    raise exception 'couple_survived_two_deletes';
  end if;
end \$\$;
"

# A cron stub so the rollback's unschedule path runs. The live project has
# no pg_cron yet; this only exists in the throwaway database.
run -v ON_ERROR_STOP=1 -c "
create schema if not exists cron;
create table if not exists cron.job (jobname text primary key);
insert into cron.job (jobname) values ('justus-push-flush'), ('justus-photo-sweep') on conflict do nothing;
create or replace function cron.unschedule(job_name text)
returns void
language plpgsql
as \$\$
begin
  delete from cron.job where jobname = job_name;
end;
\$\$;
"
run -f supabase/proposed/008_push_rollback.sql
run -v ON_ERROR_STOP=1 -c "
do \$\$
begin
  if to_regprocedure('public.delete_my_account()') is null then
    raise exception 'delete_my_account_lost_in_push_rollback';
  end if;
  if to_regclass('app_private.closed_couples') is null then
    raise exception 'closed_couples_lost_in_push_rollback';
  end if;
  if to_regclass('public.space_closures') is null then
    raise exception 'space_closures_lost_in_push_rollback';
  end if;
  if position('close_couple' in pg_get_functiondef('public.leave_couple()'::regprocedure)) = 0 then
    raise exception 'leave_lost_in_push_rollback';
  end if;
  if to_regclass('public.push_outbox') is not null or to_regclass('public.push_deliveries') is not null then
    raise exception 'push_tables_survived_push_rollback';
  end if;
  if to_regprocedure('public.claim_push_delivery(uuid,text,text)') is not null
     or to_regprocedure('public.claim_due_outbox(integer)') is not null then
    raise exception 'push_functions_survived_push_rollback';
  end if;
  if exists (select 1 from cron.job where jobname = 'justus-push-flush') then
    raise exception 'push_flush_survived_push_rollback';
  end if;
  if not exists (select 1 from cron.job where jobname = 'justus-photo-sweep') then
    raise exception 'photo_sweep_lost_in_push_rollback';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'device_tokens' and column_name = 'environment'
  ) then
    raise exception 'environment_column_dropped';
  end if;
end \$\$;
"
run -f supabase/proposed/008_push_rollback.sql
run -v ON_ERROR_STOP=1 -c "
do \$\$
begin
  if to_regprocedure('public.delete_my_account()') is null then
    raise exception 'push_rollback_not_idempotent';
  end if;
  if not exists (select 1 from cron.job where jobname = 'justus-photo-sweep') then
    raise exception 'second_push_rollback_dropped_the_photo_sweep';
  end if;
  if exists (select 1 from cron.job where jobname = 'justus-push-flush') then
    raise exception 'second_push_rollback_restored_the_flush';
  end if;
end \$\$;
"
run -f supabase/proposed/005_rollback.sql
run -v ON_ERROR_STOP=1 -c "
do \$\$
begin
  if to_regprocedure('public.delete_my_account()') is not null then
    raise exception 'delete_my_account_survived_rollback';
  end if;
  if to_regclass('public.space_closures') is not null then
    raise exception 'space_closures_survived_rollback';
  end if;
  if to_regclass('public.push_deliveries') is not null then
    raise exception 'push_deliveries_survived_rollback';
  end if;
  if exists (select 1 from cron.job where jobname = 'justus-push-flush') then
    raise exception 'push_flush_was_not_unscheduled';
  end if;
  if exists (select 1 from cron.job where jobname = 'justus-photo-sweep') then
    raise exception 'photo_sweep_was_not_unscheduled';
  end if;
  if position('close_couple' in pg_get_functiondef('public.leave_couple()'::regprocedure)) > 0 then
    raise exception 'leave_was_not_restored';
  end if;
  if not exists (
    select 1 from pg_attribute
    where attrelid = 'public.memory_notes'::regclass
      and attname = 'author_user_id'
      and attnotnull
  ) then
    raise exception 'author_user_id_not_null_missing';
  end if;
end \$\$;
"
echo "sql lifecycle passed"
