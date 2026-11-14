-- PROPOSED ONLY. Do not apply until Tom verifies.
-- This file is not a migration. scripts/sql-lifecycle.sh runs it in CI.
--
-- Depends on nothing new. Replaces app_private.guard_date_update and
-- public.leave_couple. The live copies stay in place until this is applied.
--
-- leave_couple closes the whole couple for both people. It does not hand the
-- space to the partner and it does not delete either login. The other person
-- gets a space_closures row. Photos stay in storage.objects: a direct delete
-- raises 42501 and does not remove the file. The iOS client calls the
-- proposed delete-couple-photos function, which uses the Storage API, before
-- this RPC.
--
-- Two additions to the live date guard:
--   1. A completed date may change memory_photo_path only, and only to
--      {couple_id}/{date_id}.jpg. Skipped and canceled dates stay locked.
--      The planner, snapshots, and every other column stay locked.
--   2. A handoff may change planner_user_id only. The old planner must be
--      the caller, the new planner must already be a member, and the
--      transaction must hold a row in app_private.handoff_tickets whose
--      nonce matches the transaction-local GUC. Setting the GUC alone,
--      including via set_config, does nothing: the ticket table is not in
--      the API schema and is revoked from anon and authenticated.
--
-- set_memory_photo_path is the write the iOS app uses after the storage
-- upload. A direct update of that one column is also accepted by the guard,
-- so the web app's other date rules are unchanged.

create table if not exists app_private.handoff_tickets (
  nonce text primary key
);

revoke all on table app_private.handoff_tickets from public, anon, authenticated;

create or replace function app_private.handoff_active()
returns boolean
language sql
stable
security definer
set search_path = public, app_private
as $$
  select exists (
    select 1
    from app_private.handoff_tickets
    where nonce = current_setting('app.membership_handoff', true)
  );
$$;

create or replace function app_private.begin_handoff()
returns void
language plpgsql
security definer
set search_path = public, app_private
as $$
declare
  v_nonce text := gen_random_uuid()::text;
begin
  insert into app_private.handoff_tickets (nonce) values (v_nonce);
  perform set_config('app.membership_handoff', v_nonce, true);
end;
$$;

create or replace function app_private.end_handoff()
returns void
language plpgsql
security definer
set search_path = public, app_private
as $$
declare
  v_nonce text := current_setting('app.membership_handoff', true);
begin
  delete from app_private.handoff_tickets where nonce = v_nonce;
  perform set_config('app.membership_handoff', '', true);
end;
$$;

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

create or replace function public.couples_touching_me()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select touched.id
  from app_private.couples_touched_by(auth.uid()) as touched(id)
  where auth.uid() is not null
$$;

-- Deletes the couple and the rows that reference it. Explicit deletes match
-- the live foreign keys from scripts/sql/live-fk-dump.sql, so this does not
-- depend on ON DELETE CASCADE. storage.objects is not touched.
create or replace function app_private.close_couple(p_couple uuid, p_actor uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_members uuid[];
begin
  if not exists (select 1 from public.couples where id = p_couple) then
    return;
  end if;
  perform 1 from public.couples where id = p_couple for update;

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
end;
$$;

revoke all on function app_private.handoff_active() from public, anon, authenticated;
revoke all on function app_private.begin_handoff() from public, anon, authenticated;
revoke all on function app_private.end_handoff() from public, anon, authenticated;
revoke all on function app_private.couples_touched_by(uuid) from public, anon, authenticated;
revoke all on function app_private.close_couple(uuid, uuid) from public, anon, authenticated;
revoke all on function public.couples_touching_me() from public, anon, authenticated;
grant execute on function public.couples_touching_me() to authenticated;

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

  -- Unlink and account deletion. The ticket, not the GUC string, is what
  -- allows the write. The old planner must be the caller. Every column
  -- except planner_user_id is compared from the row image, so a new column
  -- cannot slip through a handwritten list. This is ahead of the membership
  -- check because delete_my_account still moves finished nights after the
  -- login has already left.
  if app_private.handoff_active()
    and old.planner_user_id = v_uid
    and new.planner_user_id is distinct from old.planner_user_id
    and (to_jsonb(new) - 'planner_user_id' - 'updated_at')
      is not distinct from (to_jsonb(old) - 'planner_user_id' - 'updated_at')
    and exists (
      select 1 from public.couple_members
      where couple_id = new.couple_id and user_id = new.planner_user_id
    )
  then
    new.updated_at := now();
    return new;
  end if;

  -- Cancel an unrevealed night the caller still plans, including after they
  -- have left and are no longer a member. Status is the only change.
  if app_private.handoff_active()
    and old.planner_user_id = v_uid
    and old.status = 'scheduled'
    and new.status = 'canceled'
    and old.revealed_at is null
    and (to_jsonb(new) - 'status' - 'skipped_at' - 'updated_at')
      is not distinct from (to_jsonb(old) - 'status' - 'skipped_at' - 'updated_at')
  then
    new.skipped_at := now();
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
  v_couple uuid;
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
  -- The second finds the couple already gone and returns.
  perform 1 from public.couples where id = v_couple for update;
  if not exists (
    select 1 from public.couple_members
    where user_id = v_uid and couple_id = v_couple
  ) then
    return;
  end if;

  perform app_private.close_couple(v_couple, v_uid);
end;
$$;

revoke all on function public.set_memory_photo_path(uuid, text) from public, anon, authenticated;
revoke all on function public.leave_couple() from public, anon, authenticated;
grant execute on function public.set_memory_photo_path(uuid, text) to authenticated;
grant execute on function public.leave_couple() to authenticated;
