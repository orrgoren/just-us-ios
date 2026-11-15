-- Throwaway schema for scripts/sql/lifecycle.sql. Not production.
-- Postgres roles and tables the proposed files expect, with the foreign keys
-- that block auth.users deletion. No network and no live project.
--
-- Cascades and the storage delete trigger match the live project. The
-- read-only query is scripts/sql/live-fk-dump.sql. Do not treat a missing
-- trigger here as permission to delete storage.objects.

create schema if not exists auth;
create schema if not exists app_private;
create schema if not exists storage;

do $$ begin create role anon; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated; exception when duplicate_object then null; end $$;
do $$ begin create role service_role; exception when duplicate_object then null; end $$;

create table if not exists auth.users (
  id uuid primary key
);

-- Matches live auth.uid() and auth.role(). Current PostgREST sets
-- request.jwt.claims and does not set request.jwt.claim.sub or
-- request.jwt.claim.role. The old settings stay in the coalesce so a
-- fixture that still sets them keeps working.
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

create or replace function auth.role()
returns text
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )
$$;

create table if not exists storage.buckets (
  id text primary key,
  name text not null,
  public boolean not null default false
);

create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text not null,
  name text not null
);

-- Live storage.protect_delete, from pg_get_functiondef on 2026-11-14.
-- A direct delete raises 42501. Returning null would skip the row even when
-- the storage GUC is set, so SQL never removes the file bytes.
create or replace function storage.protect_delete()
returns trigger
language plpgsql
as $$
begin
  if coalesce(current_setting('storage.allow_delete_query', true), 'false') != 'true' then
    raise exception 'Direct deletion from storage tables is not allowed. Use the Storage API instead.'
      using hint = 'This prevents accidental data loss from orphaned objects.',
            errcode = '42501';
  end if;
  return null;
end;
$$;

drop trigger if exists protect_objects_delete on storage.objects;
create trigger protect_objects_delete
  before delete on storage.objects
  for each row execute function storage.protect_delete();

create table if not exists public.couples (
  id uuid primary key,
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  weekday int not null,
  local_time time not null,
  timezone text not null,
  default_duration_minutes int not null,
  invitee_display_name text not null
);

create table if not exists public.couple_members (
  couple_id uuid not null references public.couples (id) on delete cascade,
  user_id uuid not null references auth.users (id),
  display_name text not null,
  member_index int not null,
  primary key (couple_id, user_id)
);

create table if not exists public.couple_invites (
  id uuid primary key,
  couple_id uuid not null references public.couples (id) on delete cascade,
  created_by uuid not null references auth.users (id),
  token_hash text not null,
  expires_at timestamptz not null,
  redeemed_at timestamptz,
  redeemed_by uuid references auth.users (id),
  revoked_at timestamptz
);

create table if not exists public.dates (
  id uuid primary key,
  couple_id uuid not null references public.couples (id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  planner_user_id uuid not null references auth.users (id),
  status text not null,
  scheduled_at timestamptz,
  duration_minutes int not null default 90,
  location text,
  location_is_override boolean not null default false,
  public_teaser text,
  outfit_hint text,
  revealed_at timestamptz,
  skipped_at timestamptz,
  completed_at timestamptz,
  snapshot_idea_id text,
  snapshot_title text,
  snapshot_emoji text,
  snapshot_summary text,
  memory_photo_path text
);

create table if not exists public.private_date_plans (
  date_id uuid primary key references public.dates (id) on delete cascade,
  idea_id text,
  private_notes text,
  prepared_at timestamptz
);

create table if not exists public.ideas (
  id text primary key,
  title_he text,
  emoji text,
  summary_he text
);

create table if not exists public.memory_notes (
  id uuid primary key,
  date_id uuid not null references public.dates (id) on delete cascade,
  author_user_id uuid not null references auth.users (id),
  author_name text,
  note text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.mood_votes (
  date_id uuid not null references public.dates (id) on delete cascade,
  user_id uuid not null references auth.users (id),
  mood text not null,
  primary key (date_id, user_id)
);

create table if not exists public.device_tokens (
  user_id uuid not null references auth.users (id) on delete cascade,
  token text not null,
  platform text not null default 'ios',
  updated_at timestamptz not null default now(),
  primary key (user_id, token)
);

create table if not exists public.import_fingerprints (
  couple_id uuid not null references public.couples (id) on delete cascade,
  fingerprint text not null,
  created_at timestamptz not null default now(),
  primary key (couple_id, fingerprint)
);

-- No foreign key yet. Live internal_ops.couple_id has none. 003 deletes
-- orphans, then adds the key. An orphan here is how that cleanup is tested.
create table if not exists app_private.internal_ops (
  couple_id uuid not null,
  op text not null
);

insert into app_private.internal_ops (couple_id, op)
values ('00000000-0000-4000-8000-000000000099', 'orphan');

create or replace function public.is_date_planner(p_date_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.dates d
    join public.couple_members m on m.couple_id = d.couple_id
    where d.id = p_date_id
      and m.user_id = auth.uid()
      and d.planner_user_id = auth.uid()
  );
$$;

create or replace function public.is_couple_member(p_couple uuid)
returns boolean
language sql
stable
as $$
  select exists (
    select 1 from public.couple_members
    where couple_id = p_couple and user_id = auth.uid()
  );
$$;

create or replace function public.next_weekly_instant(weekday int, local_time time, timezone text, instant timestamptz)
returns timestamptz
language sql
immutable
as $$
  select instant;
$$;

grant usage on schema public to authenticated, anon, service_role;
grant select on all tables in schema public to authenticated;
