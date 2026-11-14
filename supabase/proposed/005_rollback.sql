-- PROPOSED ROLLBACK. Do not apply to vowmukhhnfhtnjlswkun unless Tom is
-- undoing 003, 004, and 006.
--
-- Dependencies, in order:
--   1. Ship the previous TestFlight build first if the current build calls
--      leave_couple or delete_my_account and then delete-couple-photos.
--      This file restores the live leave_couple, which returns nothing.
--   2. Delete the delete-couple-photos edge function in the dashboard if
--      it was deployed. This file does not remove it.
--   3. Then run this file. It unschedules justus-push-flush only when 007
--      created that job, and it drops push_outbox and push_deliveries only
--      because 002 and 006 created them.
-- The deployed send-push is still v1. This file does not redeploy it.
--
-- One transaction. Paste this whole file into the Supabase SQL editor.
-- The live function bodies are inlined below, copied from
-- supabase/proposed/live/. This file has no include directive.
--
-- psql, including scripts/sql-lifecycle.sh:
--   psql -v ON_ERROR_STOP=1 -f supabase/proposed/005_rollback.sql
-- The SQL editor has no ON_ERROR_STOP. The transaction is the stop: any
-- error rolls the whole file back.
--
-- Unschedules justus-push-flush when pg_cron has that job. pg_cron is not
-- installed on the live project today, so the block does nothing there
-- until 007 has been applied.
--
-- send-push v1 is what is deployed (verify_jwt on, body token / kind /
-- partnerName / localHour). This file does not deploy or replace it.
-- If the proposed replacement in
-- supabase/proposed/functions/send-push/index.ts was deployed and you are
-- undoing 002 and 006, restore v1 from that function's deployment history
-- in the dashboard before dropping push_deliveries. Do not redeploy v1
-- from git; the copy in git is the replacement, not v1. Leave the deployed
-- function alone when v1 is still the one that is live. The schedule is
-- removed first so it cannot call send-push after the tables are gone.
--
-- author_name, memory_photo_path, device_tokens, notification_preferences,
-- and the date-photos bucket are already live. This file does not drop them.
-- author_user_id stays NOT NULL. The statement below sets it again and
-- fails the transaction if a row is null.

begin;

do $$
begin
  if to_regnamespace('cron') is not null
     and to_regclass('cron.job') is not null
     and exists (select 1 from cron.job where jobname = 'justus-push-flush') then
    perform cron.unschedule('justus-push-flush');
  end if;
end $$;

-- LIVE SNAPSHOT of app_private.guard_date_update on vowmukhhnfhtnjlswkun.
-- Read on 2026-11-14 with pg_get_functiondef. Do not apply except as rollback.
-- This is the body before the photo-path exception in 003.

CREATE OR REPLACE FUNCTION app_private.guard_date_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_idea text;
  v_title text;
  v_emoji text;
  v_summary text;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  if not public.is_couple_member(new.couple_id) then
    raise exception 'not_a_member';
  end if;
  if new.id is distinct from old.id
    or new.couple_id is distinct from old.couple_id
    or new.created_at is distinct from old.created_at
  then
    raise exception 'forbidden';
  end if;
  if not exists (
    select 1 from public.couple_members
    where couple_id = new.couple_id and user_id = new.planner_user_id
  ) then
    raise exception 'planner_not_member';
  end if;

  -- Completion copies the real idea. Submitted snapshot text is ignored.
  if old.status = 'scheduled' and new.status = 'completed' then
    if new.planner_user_id is distinct from old.planner_user_id
      or new.scheduled_at is distinct from old.scheduled_at
      or new.duration_minutes is distinct from old.duration_minutes
      or new.location is distinct from old.location
      or new.location_is_override is distinct from old.location_is_override
      or new.public_teaser is distinct from old.public_teaser
      or new.outfit_hint is distinct from old.outfit_hint
      or new.revealed_at is distinct from old.revealed_at
      or new.skipped_at is distinct from old.skipped_at
    then
      raise exception 'invalid_transition';
    end if;

    select p.idea_id, i.title_he, i.emoji, i.summary_he
      into v_idea, v_title, v_emoji, v_summary
    from public.private_date_plans p
    left join public.ideas i on i.id = p.idea_id
    where p.date_id = new.id;

    new.snapshot_idea_id := v_idea;
    new.snapshot_title := coalesce(v_title, 'דייט שלנו');
    new.snapshot_emoji := coalesce(v_emoji, '♥');
    new.snapshot_summary := v_summary;
    new.completed_at := now();
    new.updated_at := now();
    return new;
  end if;

  if new.status <> 'completed' then
    new.snapshot_idea_id := null;
    new.snapshot_title := null;
    new.snapshot_emoji := null;
    new.snapshot_summary := null;
    new.completed_at := null;
  end if;

  if old.status in ('completed', 'skipped', 'canceled') then
    raise exception 'forbidden';
  end if;

  if new.planner_user_id is distinct from old.planner_user_id then
    if old.status <> 'draft' or new.status <> 'draft' then
      raise exception 'forbidden';
    end if;
    if new.scheduled_at is distinct from old.scheduled_at
      or new.duration_minutes is distinct from old.duration_minutes
      or new.location is distinct from old.location
      or new.location_is_override is distinct from old.location_is_override
      or new.public_teaser is distinct from old.public_teaser
      or new.outfit_hint is distinct from old.outfit_hint
      or new.revealed_at is distinct from old.revealed_at
      or new.skipped_at is distinct from old.skipped_at
    then
      raise exception 'forbidden';
    end if;
    delete from public.private_date_plans where date_id = new.id;
    new.updated_at := now();
    return new;
  end if;

  if old.planner_user_id is distinct from v_uid then
    raise exception 'not_planner';
  end if;

  if new.revealed_at is distinct from old.revealed_at then
    if old.status <> 'scheduled' or new.status <> 'scheduled' then
      raise exception 'invalid_transition';
    end if;
    if old.revealed_at is not null or new.revealed_at is null then
      raise exception 'forbidden';
    end if;
  end if;

  if old.status = 'draft' and new.status not in ('draft', 'scheduled', 'skipped', 'canceled') then
    raise exception 'invalid_transition';
  end if;
  if old.status = 'scheduled' and new.status not in ('scheduled', 'draft', 'skipped', 'canceled') then
    raise exception 'invalid_transition';
  end if;
  if old.status = 'scheduled' and new.status = 'draft' and old.revealed_at is not null then
    raise exception 'already_revealed';
  end if;

  if old.status = 'draft' and new.status = 'scheduled' then
    if new.scheduled_at is null or new.location is null then
      raise exception 'missing_schedule';
    end if;
    if not exists (select 1 from public.private_date_plans where date_id = new.id) then
      raise exception 'missing_plan';
    end if;
  end if;

  if new.status in ('skipped', 'canceled') and old.status is distinct from new.status then
    new.skipped_at := now();
  end if;

  new.updated_at := now();
  return new;
end;
$function$;

-- LIVE SNAPSHOT of app_private.touch_memory on vowmukhhnfhtnjlswkun.
-- Read on 2026-11-14 with pg_get_functiondef. Do not apply except as rollback.
-- Live memory_notes.author_user_id is NOT NULL. 001's drop-not-null statement
-- was not applied.

CREATE OR REPLACE FUNCTION app_private.touch_memory()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.date_id is distinct from old.date_id or new.author_user_id is distinct from old.author_user_id or new.created_at is distinct from old.created_at then
    raise exception 'forbidden';
  end if;
  if char_length(btrim(new.note)) < 1 or char_length(new.note) > 2000 then
    raise exception 'note_too_long';
  end if;
  new.updated_at := now();
  return new;
end;
$function$;

-- LIVE SNAPSHOT of app_private.guard_couple_update on vowmukhhnfhtnjlswkun.
-- Read on 2026-11-14 with pg_get_functiondef. Do not apply except as rollback.

CREATE OR REPLACE FUNCTION app_private.guard_couple_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.id is distinct from old.id or new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at then
    raise exception 'forbidden';
  end if;
  if new.weekday < 0 or new.weekday > 6 then
    raise exception 'invalid_weekday';
  end if;
  if new.default_duration_minutes < 30 or new.default_duration_minutes > 360 then
    raise exception 'invalid_duration';
  end if;
  if new.timezone !~ '^[A-Za-z0-9_+\\-/]{1,80}$' then
    raise exception 'invalid_timezone';
  end if;
  begin
    perform public.next_weekly_instant(new.weekday, new.local_time, new.timezone, now());
  exception
    when invalid_parameter_value then
      raise exception 'invalid_timezone';
  end;
  new.updated_at := now();
  return new;
end;
$function$;

-- LIVE SNAPSHOT of app_private.guard_invite_update on vowmukhhnfhtnjlswkun.
-- Read on 2026-11-14 with pg_get_functiondef. Do not apply except as rollback.

CREATE OR REPLACE FUNCTION app_private.guard_invite_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app_private'
AS $function$
begin
  if new.id is distinct from old.id
    or new.couple_id is distinct from old.couple_id
    or new.created_by is distinct from old.created_by
    or new.token_hash is distinct from old.token_hash
    or new.expires_at is distinct from old.expires_at
  then
    raise exception 'forbidden';
  end if;

  if new.redeemed_at is distinct from old.redeemed_at
    or new.redeemed_by is distinct from old.redeemed_by
  then
    if not exists (
      select 1 from app_private.internal_ops
      where couple_id = new.couple_id and op = 'redeem'
    ) then
      raise exception 'forbidden';
    end if;
  end if;

  if old.revoked_at is not null and new.revoked_at is distinct from old.revoked_at then
    raise exception 'forbidden';
  end if;

  return new;
end;
$function$;

-- 003 replaces leave_couple with a set-returning function. Drop it before
-- restoring the live void function. CREATE OR REPLACE cannot change the
-- return type.
drop function if exists public.leave_couple();

-- LIVE SNAPSHOT of public.leave_couple on vowmukhhnfhtnjlswkun.
-- Read on 2026-11-14 with pg_get_functiondef. Do not apply this to change
-- production. 005_rollback.sql runs it only to undo the proposed replacement.

CREATE OR REPLACE FUNCTION public.leave_couple()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  membership public.couple_members%rowtype;
  remaining int;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  select * into membership from public.couple_members where user_id = auth.uid();
  if not found then
    return;
  end if;
  delete from public.couple_members where user_id = auth.uid();
  select count(*) into remaining from public.couple_members where couple_id = membership.couple_id;
  if remaining = 0 then
    delete from public.couples where id = membership.couple_id;
  end if;
end;
$function$;

drop function if exists public.delete_my_account();
drop function if exists public.couples_touching_me();
drop function if exists public.closed_couple_ids();
drop function if exists public.ack_closed_couples(uuid[]);
drop function if exists app_private.close_couple(uuid, uuid);
drop function if exists app_private.couples_touched_by(uuid);
drop function if exists app_private.photo_delete_allowed(uuid);
drop table if exists app_private.closed_couples;
drop function if exists public.set_memory_photo_path(uuid, text);
drop function if exists public.claim_push_delivery(uuid, text, text);
drop function if exists app_private.delete_couple_photos(uuid);
drop function if exists app_private.begin_handoff();
drop function if exists app_private.end_handoff();
drop function if exists app_private.handoff_active();
drop table if exists public.space_closures;
drop table if exists app_private.handoff_tickets;
drop table if exists public.push_outbox;
drop table if exists public.push_deliveries;
alter table public.device_tokens drop column if exists environment;
alter table app_private.internal_ops drop constraint if exists internal_ops_couple_id_fkey;

do $$
begin
  if exists (select 1 from public.memory_notes where author_user_id is null) then
    raise exception 'author_user_id_has_nulls';
  end if;
  alter table public.memory_notes alter column author_user_id set not null;
end $$;

commit;
