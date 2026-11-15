-- PROPOSED ONLY. Do not apply until 002 and 006 are applied and the
-- replacement send-push is deployed. This file is not a migration and CI
-- never runs it.
--
-- 005_rollback.sql unschedules justus-push-flush when cron.job has that
-- name. The deployed send-push is still v1. Do not redeploy v1. The
-- replacement is supabase/proposed/functions/send-push/index.ts and is a
-- separate reviewed deploy, only after 002 and 006:
--   supabase functions deploy send-push --project-ref vowmukhhnfhtnjlswkun
-- Rolling the SQL back does not deploy or replace the function.
--
-- Checked on vowmukhhnfhtnjlswkun on 2026-11-14: pg_cron is not installed
-- and pg_net is not installed. Both are platform extensions. Enabling them
-- does not add a separate charge. Each run counts as one Edge Function
-- invocation.
--
-- The job posts { "kind": "flush" } every 15 minutes. The bearer is the
-- justus_service_role vault secret, the legacy service_role JWT.
-- SUPABASE_SERVICE_ROLE_KEY may be the newer sb_secret key, so the function
-- accepts the flush when the JWT role is service_role. verify_jwt is on, so
-- the gateway checks the signature first. It only sends rows already waiting
-- in push_outbox (quiet hours), and it deletes a row only after that send
-- succeeds. It does not create a weekly reminder or an invite nudge. The
-- iOS app never calls those kinds.
--
-- Create these two Vault secrets in the dashboard first. Do not paste the
-- service role into this file or into git.
--   justus_project_url    https://vowmukhhnfhtnjlswkun.supabase.co
--   justus_service_role   the service role key
-- If create extension is denied, enable pg_cron and pg_net under
-- Database → Extensions, then run the schedule statement.

create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule(
  'justus-push-flush',
  '*/15 * * * *',
  $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'justus_project_url')
      || '/functions/v1/send-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (
        select decrypted_secret from vault.decrypted_secrets where name = 'justus_service_role'
      )
    ),
    body := '{"kind":"flush"}'::jsonb,
    timeout_milliseconds := 10000
  );
  $$
);
