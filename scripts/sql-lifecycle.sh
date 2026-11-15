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
run -f supabase/proposed/002_push_deliveries.sql
# The live guards are already on the project. The throwaway database needs
# the same bodies so the triggers in lifecycle.sql exist. 003 replaces the
# date guard and leave_couple.
run -f supabase/proposed/live/guard_date_update.sql
run -f supabase/proposed/live/touch_memory.sql
run -f supabase/proposed/live/guard_couple_update.sql
run -f supabase/proposed/live/guard_invite_update.sql
run -f supabase/proposed/live/leave_couple.sql
run -f supabase/proposed/003_memory_photo_and_close.sql
run -f supabase/proposed/004_delete_my_account.sql
run -f supabase/proposed/006_push_claim_and_outbox.sql
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
