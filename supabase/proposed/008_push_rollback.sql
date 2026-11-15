-- Push-only rollback for 002/006/007. Leaves 003, 004, leave_couple,
-- delete_my_account, closed_couples, justus-photo-sweep and vault secrets
-- untouched.
-- Live send-push is v3, deployed from main at a12f1d1. This file does not deploy or replace it.
-- claim_due_outbox is dropped with the other 006 functions. 005 is the
-- rollback that also undoes 003 and 004. Do not use 005 for push alone.

begin;

do $$
begin
  if to_regnamespace('cron') is not null and to_regclass('cron.job') is not null then
    if exists (select 1 from cron.job where jobname = 'justus-push-flush') then
      perform cron.unschedule('justus-push-flush');
    end if;
  end if;
end $$;

drop function if exists public.claim_due_outbox(integer);
drop function if exists public.claim_push_delivery(uuid, text, text);
drop table if exists public.push_outbox;
drop table if exists public.push_deliveries;
-- device_tokens.environment is kept on purpose.

commit;
