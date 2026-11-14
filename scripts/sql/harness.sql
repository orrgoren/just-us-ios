-- Throwaway schema for scripts/sql/lifecycle.sql. Not production.
-- Postgres roles and tables the proposed files expect, with the foreign keys
-- that block auth.users deletion. No network and no live project.

create schema if not exists auth;
create schema if not exists app_private;
create schema if not exists storage;

do $$ begin create role anon; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated; exception when duplicate_object then null; end $$;
do $$ begin create role service_role; exception when duplicate_object then null; end $$;

create table if not exists auth.users (
  id uuid primary key
);

create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
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
  private_notes text
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

create table if not exists app_private.internal_ops (
  couple_id uuid,
  op text
);

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
