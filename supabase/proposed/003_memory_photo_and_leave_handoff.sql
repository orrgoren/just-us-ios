-- PROPOSED ONLY. Do not apply until Tom verifies.
-- This file is not a migration and CI never runs it.
--
-- Depends on nothing new. Replaces app_private.guard_date_update and
-- public.leave_couple. The live copies stay in place until this is applied.
--
-- Two additions to the live date guard, and nothing else:
--   1. A completed date may change memory_photo_path only, and only to
--      {couple_id}/{date_id}.jpg. Skipped and canceled dates stay locked.
--      The planner, snapshots, and every other column stay locked.
--   2. While app.membership_handoff is on for this transaction, the only
--      permitted change is planner_user_id, and the new planner must already
--      be a member. leave_couple and delete_my_account set that flag.
--      A client cannot set it through PostgREST.
--
-- set_memory_photo_path is the write the iOS app uses after the storage
-- upload. A direct update of that one column is also accepted by the guard,
-- so the web app's other date rules are unchanged.

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

  -- Unlink and account deletion. Transaction-local, and only the planner moves.
  -- The caller may already have left, which is why this is ahead of the
  -- membership check: delete_my_account still has to move finished nights
  -- off the departing login. The old planner must be the caller, and the new
  -- planner must already be a member. A client cannot set the flag.
  if current_setting('app.membership_handoff', true) = 'on'
    and old.planner_user_id = v_uid
    and new.planner_user_id is distinct from old.planner_user_id
    and new.status is not distinct from old.status
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
    and new.memory_photo_path is not distinct from old.memory_photo_path
    and exists (
      select 1 from public.couple_members
      where couple_id = new.couple_id and user_id = new.planner_user_id
    )
  then
    new.updated_at := now();
    return new;
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

create or replace function public.leave_couple()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  membership public.couple_members%rowtype;
  partner uuid;
  remaining int;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select * into membership
  from public.couple_members
  where user_id = v_uid;
  if not found then
    return;
  end if;

  select user_id into partner
  from public.couple_members
  where couple_id = membership.couple_id
    and user_id <> v_uid
  limit 1;

  if partner is not null then
    -- The web guard rejects a planner change on a scheduled night. Cancel an
    -- unrevealed one while the leaver is still its planner. That uses the
    -- existing scheduled → canceled path, and the follow-up trigger opens
    -- the next draft instead of leaving the partner with nobody who can edit.
    -- Drop the sealed plan first so a later planner change cannot reveal it.
    delete from public.private_date_plans as plan
    using public.dates as night
    where plan.date_id = night.id
      and night.couple_id = membership.couple_id
      and night.planner_user_id = v_uid
      and night.status = 'scheduled'
      and night.revealed_at is null;

    update public.dates
    set status = 'canceled'
    where couple_id = membership.couple_id
      and planner_user_id = v_uid
      and status = 'scheduled'
      and revealed_at is null;

    -- A draft reassignment through the normal guard deletes the sealed plan.
    -- Do the same here so the handoff does not reveal it to the new planner.
    delete from public.private_date_plans as plan
    using public.dates as night
    where plan.date_id = night.id
      and night.couple_id = membership.couple_id
      and night.planner_user_id = v_uid
      and night.status = 'draft'
      and night.revealed_at is null;

    perform set_config('app.membership_handoff', 'on', true);
    update public.dates
    set planner_user_id = partner
    where couple_id = membership.couple_id
      and planner_user_id = v_uid
      and status in ('draft', 'scheduled');
    perform set_config('app.membership_handoff', 'off', true);
  end if;

  -- Keep the name on notes the partner can still read after this login is gone.
  update public.memory_notes
  set author_name = coalesce(nullif(btrim(author_name), ''), membership.display_name)
  where author_user_id = v_uid
    and (author_name is null or btrim(author_name) = '');

  delete from public.couple_members where user_id = v_uid;

  select count(*) into remaining
  from public.couple_members
  where couple_id = membership.couple_id;
  if remaining = 0 then
    delete from public.couples where id = membership.couple_id;
  end if;
end;
$$;

revoke all on function public.set_memory_photo_path(uuid, text) from public, anon, authenticated;
revoke all on function public.leave_couple() from public, anon, authenticated;
grant execute on function public.set_memory_photo_path(uuid, text) to authenticated;
grant execute on function public.leave_couple() to authenticated;
