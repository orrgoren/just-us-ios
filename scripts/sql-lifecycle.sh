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
run -f supabase/proposed/003_memory_photo_and_leave_handoff.sql
run -f supabase/proposed/004_delete_my_account.sql
run -f supabase/proposed/006_push_claim_and_outbox.sql
run -f scripts/sql/lifecycle.sql
echo "sql lifecycle passed"
