-- PROPOSED ONLY. Do not apply until Tom verifies.
-- This file is not a migration and CI never runs it.
--
-- Apply 002, 003, and 006 first. If either partner deletes their account,
-- the whole couple goes: the couple row, scheduled and planned dates,
-- memories, date-photos, invites, both members' device tokens, push
-- deliveries, and pending push_outbox rows. The shared idea catalog is not
-- couple data and stays. The other partner's login stays. A space_closures
-- row tells their next launch that the space was closed.
--
-- Someone who already unlinked is not closing that couple. The leftover
-- updates only detach foreign keys so their login can be removed. 003's
-- handoff ticket is what lets those updates pass the guards.
-- Live memory_notes.author_user_id is still NOT NULL. The drop below is
-- proposed, not already applied.
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

alter table public.memory_notes alter column author_user_id drop not null;

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

  if app_private.handoff_active()
    and old.author_user_id is not distinct from auth.uid()
    and new.author_user_id is null
    and new.author_name is not null
    and char_length(btrim(new.author_name)) > 0
    and (to_jsonb(new) - 'author_user_id' - 'author_name' - 'updated_at')
      is not distinct from (to_jsonb(old) - 'author_user_id' - 'author_name' - 'updated_at')
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
  if app_private.handoff_active()
    and old.created_by = auth.uid()
    and new.created_by is distinct from old.created_by
    and (to_jsonb(new) - 'created_by' - 'updated_at')
      is not distinct from (to_jsonb(old) - 'created_by' - 'updated_at')
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
  if app_private.handoff_active() then
    if (to_jsonb(new) - 'created_by' - 'redeemed_by')
      is distinct from (to_jsonb(old) - 'created_by' - 'redeemed_by')
    then
      raise exception 'forbidden';
    end if;
    if new.created_by is distinct from old.created_by and (
      old.created_by is distinct from auth.uid()
      or not exists (
        select 1 from public.couple_members
        where couple_id = new.couple_id and user_id = new.created_by
      )
    ) then
      raise exception 'forbidden';
    end if;
    if new.redeemed_by is distinct from old.redeemed_by and (
      new.redeemed_by is not null
      or old.redeemed_by is distinct from auth.uid()
    ) then
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
  v_couple uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  -- A current member closes the whole space. Someone who already left only
  -- detaches leftover foreign keys, further down, so their login can go.
  select display_name, couple_id into v_name, v_couple
  from public.couple_members
  where user_id = v_uid
  limit 1;

  if v_couple is not null then
    perform 1 from public.couples where id = v_couple for update;

    insert into public.space_closures (user_id)
    select member.user_id
    from public.couple_members as member
    where member.couple_id = v_couple
      and member.user_id <> v_uid
    on conflict (user_id) do update
      set closed_at = excluded.closed_at;

    perform app_private.delete_couple_photos(v_couple);

    if to_regclass('public.push_outbox') is not null then
      delete from public.push_outbox as pending
      where pending.caller_user_id in (
          select member.user_id from public.couple_members as member where member.couple_id = v_couple
        )
        or pending.recipient_user_id in (
          select member.user_id from public.couple_members as member where member.couple_id = v_couple
        );
    end if;

    if to_regclass('public.push_deliveries') is not null then
      delete from public.push_deliveries as delivery
      where delivery.recipient_user_id in (
        select member.user_id from public.couple_members as member where member.couple_id = v_couple
      );
    end if;

    delete from public.device_tokens as device
    where device.user_id in (
      select member.user_id from public.couple_members as member where member.couple_id = v_couple
    );

    delete from public.couples where id = v_couple;
  end if;

  if v_couple is null then
    -- Already left, and someone else may still be there.
    perform app_private.begin_handoff();
    update public.couples as owned
    set created_by = (
      select member.user_id
      from public.couple_members as member
      where member.couple_id = owned.id
      order by member.member_index
      limit 1
    )
    where owned.created_by = v_uid
      and exists (
        select 1 from public.couple_members as member
        where member.couple_id = owned.id
      );

    update public.couple_invites as invite
    set created_by = (
      select member.user_id
      from public.couple_members as member
      where member.couple_id = invite.couple_id
      order by member.member_index
      limit 1
    )
    where invite.created_by = v_uid
      and exists (
        select 1 from public.couple_members as member
        where member.couple_id = invite.couple_id
      );

    update public.couple_invites
    set redeemed_by = null
    where redeemed_by = v_uid;

    delete from public.private_date_plans as plan
    using public.dates as night
    where plan.date_id = night.id
      and night.planner_user_id = v_uid
      and night.status = 'scheduled'
      and night.revealed_at is null;

    update public.dates as night
    set status = 'canceled'
    where night.planner_user_id = v_uid
      and night.status = 'scheduled'
      and night.revealed_at is null;

    update public.dates as night
    set planner_user_id = (
      select member.user_id
      from public.couple_members as member
      where member.couple_id = night.couple_id
      order by member.member_index
      limit 1
    )
    where night.planner_user_id = v_uid
      and exists (
        select 1 from public.couple_members as member
        where member.couple_id = night.couple_id
      );

    update public.memory_notes
    set author_name = coalesce(
          nullif(btrim(author_name), ''),
          nullif(btrim(v_name), ''),
          'Just Us'
        ),
        author_user_id = null
    where author_user_id = v_uid;
    perform app_private.end_handoff();

    delete from public.mood_votes where user_id = v_uid;
  end if;

  delete from auth.users where id = v_uid;
end;
$$;

revoke all on function public.delete_my_account() from public, anon, authenticated;
grant execute on function public.delete_my_account() to authenticated;
