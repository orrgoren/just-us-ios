-- Applied live after 006. Do not re-apply. This file is not a migration.
-- scripts/sql-lifecycle.sh applies it. Without pg_cron, pg_net, and both
-- vault secrets, the schedule block skips itself.
--
-- 008_push_rollback.sql is the push-only rollback. It unschedules
-- justus-push-flush and drops the push tables. It leaves the photo sweep
-- alone. 005_rollback.sql also undoes 003 and 004 and must never be applied.
-- Live send-push is v3, deployed from main at a12f1d1 with verify_jwt on.
-- The source is supabase/proposed/functions/send-push/index.ts.
-- Rolling the SQL back does not deploy or replace the function.
--
-- pg_cron and pg_net are installed on the live project as of 2026-11-15.
-- Both are platform extensions. Each run counts as one Edge Function
-- invocation.
--
-- The job posts { "kind": "flush" } every 15 minutes. The bearer is the
-- justus_service_role vault secret, and that secret has to be the legacy
-- service_role JWT. Putting an sb_secret key in that vault secret breaks
-- this flush and the photo sweep, because both functions recognize the
-- cron by the JWT role claim. verify_jwt is on, so the gateway checks the
-- signature first. The flush deletes a row on a final decision and keeps
-- it only for a retryable APNs failure, up to the attempt cap. It does not
-- create a weekly reminder or an invite nudge. The iOS app never calls
-- those kinds.
--
-- Create these two Vault secrets in the dashboard first. Do not paste the
-- service role into this file or into git.
--   justus_project_url    https://vowmukhhnfhtnjlswkun.supabase.co
--   justus_service_role   the legacy service_role JWT
-- Enable pg_cron and pg_net under Database → Extensions before relying on
-- the schedule. Re-running this block replaces the job.

-- Push flush. Same vault guard as the photo sweep in 003. Skipped until
-- pg_cron, pg_net, and both vault secrets exist.
do $$
begin
  if to_regnamespace('cron') is null
     or to_regnamespace('net') is null
     or to_regclass('vault.decrypted_secrets') is null
  then
    raise notice 'push flush not scheduled; enable pg_cron and pg_net and create vault secrets justus_project_url and justus_service_role';
    return;
  end if;
  if (select count(*) from vault.decrypted_secrets where name in ('justus_project_url', 'justus_service_role')) < 2 then
    raise notice 'push flush not scheduled; vault is missing justus_project_url or justus_service_role';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'justus-push-flush') then
    perform cron.unschedule('justus-push-flush');
  end if;
  perform cron.schedule(
    'justus-push-flush',
    '*/15 * * * *',
    $cron$
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
    $cron$
  );
end $$;
