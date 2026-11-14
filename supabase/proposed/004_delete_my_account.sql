-- PROPOSED ONLY. Do not apply until Tom verifies.
-- This file is not a migration and CI never runs it.
--
-- Apply 003_memory_photo_and_leave_handoff.sql first. Account deletion
-- reassigns dates.planner_user_id, and the live date guard rejects that on
-- a completed or scheduled night. 003 adds the transaction-local exception.
--
-- The previous delete_my_account fails on the live schema:
--   couples.created_by, couple_invites.created_by, and dates.planner_user_id
--   reference auth.users with no ON DELETE, and the couple and invite guards
--   forbid changing created_by.
--   couple_invites.redeemed_by cannot be updated unless a redeem op is open.
--   mood_votes.user_id is part of the primary key, so it cannot be nulled.
--   memory_notes.author_user_id is NOT NULL, and touch_memory forbids
--   changing it.
--   The date guard rejects planner changes on completed and scheduled nights
--   and rejects every later update of a finished night.
--
-- The partner keeps the couple, the dates, the snapshots, the photos, and
-- the notes. Notes keep author_name (filled from the member's display name
-- when it is empty) and author_user_id is detached. The leaver's mood rows
-- are deleted because the primary key cannot outlive the user. The partner's
-- mood rows stay. Unrevealed draft and scheduled plans are not transferred.

alter table public.memory_notes alter column author_user_id drop not null;

create or replace function app_private.touch_memory()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- A detached note is the partner's copy of what was written. It stays.
  if old.author_user_id is null then
    if new.note is distinct from old.note
      or new.author_name is distinct from old.author_name
      or new.author_user_id is not null
      or new.date_id is distinct from old.date_id
      or new.created_at is distinct from old.created_at
    then
      raise exception 'forbidden';
    end if;
    new.updated_at := now();
    return new;
  end if;

  if current_setting('app.membership_handoff', true) = 'on'
    and new.date_id is not distinct from old.date_id
    and new.created_at is not distinct from old.created_at
    and new.note is not distinct from old.note
    and old.author_user_id is not distinct from auth.uid()
    and new.author_user_id is null
    and new.author_name is not null
    and char_length(btrim(new.author_name)) > 0
  then
    new.updated_at := now();
    return new;
  end if;

  if new.date_id is distinct from old.date_id
    or new.author_user_id is distinct from old.author_user_id
    or new.created_at is distinct from old.created_at
  then
    raise exception 'forbidden';
  end if;
  if char_length(btrim(new.note)) < 1 or char_length(new.note) > 2000 then
    raise exception 'note_too_long';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create or replace function app_private.guard_couple_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if current_setting('app.membership_handoff', true) = 'on'
    and new.created_by is distinct from old.created_by
    and new.id is not distinct from old.id
    and new.created_at is not distinct from old.created_at
    and new.weekday is not distinct from old.weekday
    and new.local_time is not distinct from old.local_time
    and new.timezone is not distinct from old.timezone
    and new.default_duration_minutes is not distinct from old.default_duration_minutes
    and new.invitee_display_name is not distinct from old.invitee_display_name
    and exists (
      select 1 from public.couple_members
      where couple_id = new.id and user_id = new.created_by
    )
  then
    new.updated_at := now();
    return new;
  end if;

  if new.id is distinct from old.id
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at
  then
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
$$;

create or replace function app_private.guard_invite_update()
returns trigger
language plpgsql
security definer
set search_path = public, app_private
as $$
begin
  if current_setting('app.membership_handoff', true) = 'on' then
    if new.id is distinct from old.id
      or new.couple_id is distinct from old.couple_id
      or new.token_hash is distinct from old.token_hash
      or new.expires_at is distinct from old.expires_at
      or new.redeemed_at is distinct from old.redeemed_at
      or new.revoked_at is distinct from old.revoked_at
    then
      raise exception 'forbidden';
    end if;
    if new.created_by is distinct from old.created_by and not exists (
      select 1 from public.couple_members
      where couple_id = new.couple_id and user_id = new.created_by
    ) then
      raise exception 'forbidden';
    end if;
    if new.redeemed_by is distinct from old.redeemed_by and new.redeemed_by is not null then
      raise exception 'forbidden';
    end if;
    return new;
  end if;

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
$$;

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_name text;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  -- Leave can run first. The login is then no longer a member, but finished
  -- nights, notes, and invites still reference it. Hand those to whoever
  -- stayed. A couple with nobody else is removed instead.
  select display_name into v_name
  from public.couple_members
  where user_id = v_uid
  limit 1;

  perform set_config('app.membership_handoff', 'on', true);

  update public.couples as owned
  set created_by = (
    select member.user_id
    from public.couple_members as member
    where member.couple_id = owned.id
      and member.user_id <> v_uid
    order by member.member_index
    limit 1
  )
  where owned.created_by = v_uid
    and exists (
      select 1 from public.couple_members as member
      where member.couple_id = owned.id and member.user_id <> v_uid
    );

  update public.couple_invites as invite
  set created_by = (
    select member.user_id
    from public.couple_members as member
    where member.couple_id = invite.couple_id
      and member.user_id <> v_uid
    order by member.member_index
    limit 1
  )
  where invite.created_by = v_uid
    and exists (
      select 1 from public.couple_members as member
      where member.couple_id = invite.couple_id and member.user_id <> v_uid
    );

  update public.couple_invites
  set redeemed_by = null
  where redeemed_by = v_uid;

  -- Do not hand an unrevealed plan to the partner. Revealed and completed
  -- plans stay, because that night is already shared history.
  delete from public.private_date_plans as plan
  using public.dates as night
  where plan.date_id = night.id
    and night.planner_user_id = v_uid
    and night.revealed_at is null
    and night.status <> 'completed'
    and exists (
      select 1 from public.couple_members as member
      where member.couple_id = night.couple_id and member.user_id <> v_uid
    );

  update public.dates as night
  set planner_user_id = (
    select member.user_id
    from public.couple_members as member
    where member.couple_id = night.couple_id
      and member.user_id <> v_uid
    order by member.member_index
    limit 1
  )
  where night.planner_user_id = v_uid
    and exists (
      select 1 from public.couple_members as member
      where member.couple_id = night.couple_id and member.user_id <> v_uid
    );

  update public.memory_notes
  set author_name = coalesce(
        nullif(btrim(author_name), ''),
        nullif(btrim(v_name), ''),
        'Just Us'
      ),
      author_user_id = null
  where author_user_id = v_uid;

  -- mood_votes.user_id is in the primary key, so the row cannot stay after
  -- the user is gone. This removes only the leaver's votes.
  delete from public.mood_votes where user_id = v_uid;

  delete from public.couple_members where user_id = v_uid;

  delete from public.couples as owned
  where owned.created_by = v_uid
    and not exists (
      select 1 from public.couple_members as member
      where member.couple_id = owned.id and member.user_id <> v_uid
    );

  perform set_config('app.membership_handoff', 'off', true);

  delete from auth.users where id = v_uid;
end;
$$;

revoke all on function public.delete_my_account() from public, anon, authenticated;
grant execute on function public.delete_my_account() to authenticated;
