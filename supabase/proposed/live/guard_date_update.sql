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
