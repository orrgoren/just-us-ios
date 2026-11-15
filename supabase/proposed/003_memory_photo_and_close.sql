-- PROPOSED ONLY. Do not apply until Tom verifies.
-- This file is not a migration. scripts/sql-lifecycle.sh runs it in CI.
--
-- Deploy order: this file first, then the delete-couple-photos edge
-- function, then the TestFlight build. The build calls leave_couple or
-- delete_my_account and only then the function. Shipping the build first
-- calls an RPC shape that is not live yet.
--
-- A failed function call leaves the couple id in app_private.closed_couples.
-- The schedule at the bottom of this file uses pg_cron and pg_net, both
-- free platform extensions, to post {"sweep":true} to the function every
-- 15 minutes. The bearer is the justus_service_role vault secret. The
-- function drains those rows and deletes a row only after its photos are
-- gone. Enable pg_cron and pg_net, and create the vault secrets
-- justus_project_url and justus_service_role, before relying on the
-- schedule. The block skips itself when those are missing, so re-run this
-- file after they exist. Do not paste the service role into git.
--
-- Depends on nothing new. Replaces app_private.guard_date_update and
-- public.leave_couple. The live copies stay in place until this is applied.
--
-- leave_couple closes the whole couple for both people. It does not hand
-- the space to anyone and it does not delete either login. It returns the
-- couple id it closed and records that id. The other person gets a
-- space_closures row. Photos stay in storage.objects. A direct delete
-- raises 42501 and does not remove the file. The edge function runs after
-- this RPC and deletes photos only for a returned id whose couple row is
-- already gone.
--
-- One addition to the live date guard: a completed date may change
-- memory_photo_path only, and only to {couple_id}/{date_id}.jpg. Skipped
-- and canceled dates stay locked. The planner, snapshots, and every other
-- column stay locked.
--
-- set_memory_photo_path is the write the iOS app uses after the storage
-- upload. A direct update of that one column is also accepted by the guard,
-- so the web app's other date rules are unchanged.

drop function if exists public.couples_touching_me();

-- Photos are removed by the Storage API in delete-couple-photos, not here.
create table if not exists public.space_closures (
  user_id uuid primary key references auth.users (id) on delete cascade,
  closed_at timestamptz not null default now()
);

alter table public.space_closures enable row level security;
revoke all on table public.space_closures from public, anon, authenticated;
grant select, delete on table public.space_closures to authenticated;

drop policy if exists space_closures_read on public.space_closures;
create policy space_closures_read on public.space_closures
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists space_closures_ack on public.space_closures;
create policy space_closures_ack on public.space_closures
  for delete to authenticated
  using (user_id = auth.uid());

-- Orphan ops would make the new foreign key fail. Remove them first.
delete from app_private.internal_ops as op
where not exists (
  select 1 from public.couples as couple where couple.id = op.couple_id
);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'internal_ops_couple_id_fkey'
      and conrelid = 'app_private.internal_ops'::regclass
  ) then
    alter table app_private.internal_ops
      add constraint internal_ops_couple_id_fkey
      foreign key (couple_id) references public.couples (id) on delete cascade;
  end if;
end $$;

create or replace function app_private.couples_touched_by(p_uid uuid)
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select couple.id from public.couples as couple where couple.created_by = p_uid
  union
  select member.couple_id from public.couple_members as member where member.user_id = p_uid
  union
  select night.couple_id from public.dates as night where night.planner_user_id = p_uid
  union
  select night.couple_id
  from public.memory_notes as note
  join public.dates as night on night.id = note.date_id
  where note.author_user_id = p_uid
  union
  select night.couple_id
  from public.mood_votes as vote
  join public.dates as night on night.id = vote.date_id
  where vote.user_id = p_uid
  union
  select invite.couple_id from public.couple_invites as invite
  where invite.created_by = p_uid or invite.redeemed_by = p_uid
$$;

-- The couple ids close_couple actually removed. Not every couple the
-- caller ever touched. authenticated cannot read this table.
create table if not exists app_private.closed_couples (
  couple_id uuid primary key,
  closed_by uuid not null,
  closed_at timestamptz not null default now()
);
revoke all on table app_private.closed_couples from public, anon, authenticated;

-- Deletes the couple and the rows that reference it. Returns that id only
-- when the couple row was removed. Explicit deletes match the live foreign
-- keys from scripts/sql/live-fk-dump.sql. storage.objects is not touched.
drop function if exists app_private.close_couple(uuid, uuid);
create or replace function app_private.close_couple(p_couple uuid, p_actor uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_members uuid[];
begin
  if not exists (select 1 from public.couples where id = p_couple) then
    return null;
  end if;
  perform 1 from public.couples where id = p_couple for update;
  if not exists (select 1 from public.couples where id = p_couple) then
    return null;
  end if;

  select coalesce(array_agg(user_id), '{}') into v_members
  from public.couple_members
  where couple_id = p_couple;

  insert into public.space_closures (user_id)
  select member_id
  from unnest(v_members) as member_id
  where member_id is distinct from p_actor
  on conflict (user_id) do update set closed_at = excluded.closed_at;

  if to_regclass('public.push_outbox') is not null then
    delete from public.push_outbox
    where caller_user_id = any (v_members)
       or recipient_user_id = any (v_members);
  end if;
  if to_regclass('public.push_deliveries') is not null then
    delete from public.push_deliveries
    where recipient_user_id = any (v_members);
  end if;
  delete from public.device_tokens where user_id = any (v_members);

  delete from public.mood_votes
  where date_id in (select id from public.dates where couple_id = p_couple);
  delete from public.memory_notes
  where date_id in (select id from public.dates where couple_id = p_couple);
  delete from public.private_date_plans
  where date_id in (select id from public.dates where couple_id = p_couple);
  delete from public.dates where couple_id = p_couple;
  delete from public.couple_invites where couple_id = p_couple;
  delete from public.couple_members where couple_id = p_couple;
  if to_regclass('public.import_fingerprints') is not null then
    delete from public.import_fingerprints where couple_id = p_couple;
  end if;
  delete from app_private.internal_ops where couple_id = p_couple;
  delete from public.couples where id = p_couple;

  insert into app_private.closed_couples (couple_id, closed_by)
  values (p_couple, p_actor)
  on conflict (couple_id) do update
    set closed_by = excluded.closed_by,
        closed_at = now();
  return p_couple;
end;
$$;

-- Ids this caller closed whose couple row is gone. A couple they merely
-- touched, and a couple that still exists, is not returned.
create or replace function public.closed_couple_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select recorded.couple_id
  from app_private.closed_couples as recorded
  where recorded.closed_by = auth.uid()
    and not exists (
      select 1 from public.couples as couple
      where couple.id = recorded.couple_id
    )
$$;

create or replace function public.ack_closed_couples(p_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or p_ids is null then
    return;
  end if;
  delete from app_private.closed_couples as recorded
  where recorded.closed_by = auth.uid()
    and recorded.couple_id = any (p_ids)
    and not exists (
      select 1 from public.couples as couple
      where couple.id = recorded.couple_id
    );
end;
$$;

create or replace function app_private.photo_delete_allowed(p_couple uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select not exists (select 1 from public.couples where id = p_couple)
$$;

revoke all on function app_private.couples_touched_by(uuid) from public, anon, authenticated;
revoke all on function app_private.close_couple(uuid, uuid) from public, anon, authenticated;
revoke all on function app_private.photo_delete_allowed(uuid) from public, anon, authenticated;
revoke all on function public.closed_couple_ids() from public, anon, authenticated;
revoke all on function public.ack_closed_couples(uuid[]) from public, anon, authenticated;
grant execute on function public.closed_couple_ids() to authenticated;
grant execute on function public.ack_closed_couples(uuid[]) to authenticated;

-- PostgREST exposes public. The edge function calls this with the service
-- role. It is the same check as app_private.photo_delete_allowed.
create or replace function public.photo_delete_allowed(p_couple uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select app_private.photo_delete_allowed(p_couple)
$$;

-- At most 50 closed couples whose row is already gone. The sweep uses this.
-- authenticated cannot list another person's closures.
create or replace function public.closed_couples_pending(p_limit integer)
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select recorded.couple_id
  from app_private.closed_couples as recorded
  where app_private.photo_delete_allowed(recorded.couple_id)
  order by recorded.closed_at
  limit least(greatest(coalesce(p_limit, 50), 0), 50)
$$;

-- Removes swept rows. A user JWT cannot call this: closed_by is often a
-- login that delete_my_account already removed, so auth.uid() would match
-- nothing. The service role is the sweep's caller.
create or replace function public.ack_swept_couples(p_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') is distinct from 'service_role' then
    raise exception 'forbidden';
  end if;
  if p_ids is null or cardinality(p_ids) > 50 then
    raise exception 'too_many';
  end if;
  delete from app_private.closed_couples as recorded
  where recorded.couple_id = any (p_ids)
    and app_private.photo_delete_allowed(recorded.couple_id);
end;
$$;

revoke all on function public.photo_delete_allowed(uuid) from public, anon, authenticated;
revoke all on function public.closed_couples_pending(integer) from public, anon, authenticated;
revoke all on function public.ack_swept_couples(uuid[]) from public, anon, authenticated;
grant execute on function public.photo_delete_allowed(uuid) to service_role;
grant execute on function public.closed_couples_pending(integer) to service_role;
grant execute on function public.ack_swept_couples(uuid[]) to service_role;

create or replace function app_private.guard_date_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_idea text;
  v_title text;
  v_emoji text;
  v_summary text;
  v_photo text;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  if new.id is distinct from old.id
    or new.couple_id is distinct from old.couple_id
    or new.created_at is distinct from old.created_at
  then
    raise exception 'forbidden';
  end if;

  if not public.is_couple_member(new.couple_id) then
    raise exception 'not_a_member';
  end if;

  -- The photo lives on a finished night. The original planner may already
  -- have left, so this is checked before planner_not_member. Any other
  -- column, including a cleared path, still falls through and is rejected.
  v_photo := lower(new.couple_id::text) || '/' || lower(new.id::text) || '.jpg';
  if old.status = 'completed'
    and new.status = 'completed'
    and new.planner_user_id is not distinct from old.planner_user_id
    and new.scheduled_at is not distinct from old.scheduled_at
    and new.duration_minutes is not distinct from old.duration_minutes
    and new.location is not distinct from old.location
    and new.location_is_override is not distinct from old.location_is_override
    and new.public_teaser is not distinct from old.public_teaser
    and new.outfit_hint is not distinct from old.outfit_hint
    and new.revealed_at is not distinct from old.revealed_at
    and new.skipped_at is not distinct from old.skipped_at
    and new.completed_at is not distinct from old.completed_at
    and new.snapshot_idea_id is not distinct from old.snapshot_idea_id
    and new.snapshot_title is not distinct from old.snapshot_title
    and new.snapshot_emoji is not distinct from old.snapshot_emoji
    and new.snapshot_summary is not distinct from old.snapshot_summary
    and new.memory_photo_path is distinct from old.memory_photo_path
    and new.memory_photo_path is not distinct from v_photo
  then
    new.updated_at := now();
    return new;
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
$$;

create or replace function public.set_memory_photo_path(p_date_id uuid, p_path text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_date public.dates%rowtype;
  v_photo text;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;

  select * into v_date
  from public.dates
  where id = p_date_id
  for update;

  if not found then
    raise exception 'not_found';
  end if;
  if not public.is_couple_member(v_date.couple_id) then
    raise exception 'not_a_member';
  end if;
  if v_date.status <> 'completed' then
    raise exception 'forbidden';
  end if;

  v_photo := lower(v_date.couple_id::text) || '/' || lower(v_date.id::text) || '.jpg';
  if p_path is distinct from v_photo then
    raise exception 'forbidden';
  end if;
  if v_date.memory_photo_path is not distinct from v_photo then
    return;
  end if;

  update public.dates
  set memory_photo_path = v_photo
  where id = v_date.id
    and couple_id = v_date.couple_id
    and status = 'completed';
end;
$$;

drop function if exists public.leave_couple();
create or replace function public.leave_couple()
returns setof uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_couple uuid;
  v_closed uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select couple_id into v_couple
  from public.couple_members
  where user_id = v_uid;
  if not found then
    return;
  end if;

  -- One couple row lock. Two people leaving at once take this in order.
  -- The second finds the couple already gone and returns no id.
  perform 1 from public.couples where id = v_couple for update;
  if not exists (
    select 1 from public.couple_members
    where user_id = v_uid and couple_id = v_couple
  ) then
    return;
  end if;

  v_closed := app_private.close_couple(v_couple, v_uid);
  if v_closed is not null then
    return next v_closed;
  end if;
end;
$$;

revoke all on function public.set_memory_photo_path(uuid, text) from public, anon, authenticated;
revoke all on function public.leave_couple() from public, anon, authenticated;
grant execute on function public.set_memory_photo_path(uuid, text) to authenticated;
grant execute on function public.leave_couple() to authenticated;

-- Photo sweep. Free extensions only. Skipped until pg_cron, pg_net, and the
-- two vault secrets exist. Re-running this block replaces the job.
do $$
begin
  if to_regnamespace('cron') is null
     or to_regnamespace('net') is null
     or to_regclass('vault.decrypted_secrets') is null
  then
    raise notice 'photo sweep not scheduled; enable pg_cron and pg_net and create vault secrets justus_project_url and justus_service_role, then re-run this block';
    return;
  end if;
  if (select count(*) from vault.decrypted_secrets where name in ('justus_project_url', 'justus_service_role')) < 2 then
    raise notice 'photo sweep not scheduled; vault is missing justus_project_url or justus_service_role';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'justus-photo-sweep') then
    perform cron.unschedule('justus-photo-sweep');
  end if;
  perform cron.schedule(
    'justus-photo-sweep',
    '*/15 * * * *',
    $cron$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'justus_project_url')
        || '/functions/v1/delete-couple-photos',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || (
          select decrypted_secret from vault.decrypted_secrets where name = 'justus_service_role'
        )
      ),
      body := '{"sweep":true}'::jsonb,
      timeout_milliseconds := 10000
    );
    $cron$
  );
end $$;
