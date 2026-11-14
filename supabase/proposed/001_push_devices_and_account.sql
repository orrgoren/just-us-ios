-- PROPOSED ONLY. Do not apply until Orr approves.
-- This file is not a migration in the web repo and CI never runs it.
-- Review foreign keys against the live schema before applying.
-- The iOS app calls delete_my_account and leave_couple and treats a missing
-- function as "nothing changed".

create table if not exists public.device_tokens (
  user_id uuid not null references auth.users (id) on delete cascade,
  token text not null,
  platform text not null default 'ios',
  updated_at timestamptz not null default now(),
  primary key (user_id, token)
);

alter table public.device_tokens enable row level security;

create policy device_tokens_own on public.device_tokens
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create table if not exists public.notification_preferences (
  user_id uuid primary key references auth.users (id) on delete cascade,
  partner_mood boolean not null default true,
  plan_ready boolean not null default true,
  invite_accepted boolean not null default true,
  weekly_reminder boolean not null default true
);

alter table public.notification_preferences enable row level security;

create policy notification_preferences_own on public.notification_preferences
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

alter table public.memory_notes add column if not exists author_name text;
alter table public.memory_notes alter column author_user_id drop not null;
alter table public.dates add column if not exists memory_photo_path text;

insert into storage.buckets (id, name, public)
values ('date-photos', 'date-photos', false)
on conflict (id) do nothing;

-- Path shape: {couple_id}/{date_id}.jpg. Confirm the storage policy matches
-- the couple_members row for auth.uid() before enabling it.

create or replace function public.leave_couple()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  membership public.couple_members%rowtype;
  remaining int;
begin
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
$$;

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  membership public.couple_members%rowtype;
  partner uuid;
  remaining int;
begin
  select * into membership from public.couple_members where user_id = auth.uid();
  if found then
    select user_id into partner
      from public.couple_members
      where couple_id = membership.couple_id and user_id <> auth.uid()
      limit 1;
    if partner is not null then
      update public.dates
        set planner_user_id = partner
        where couple_id = membership.couple_id and planner_user_id = auth.uid();
      update public.memory_notes
        set author_name = coalesce(author_name, membership.display_name),
            author_user_id = null
        where author_user_id = auth.uid();
      delete from public.couple_members where user_id = auth.uid();
    else
      delete from public.couples where id = membership.couple_id;
    end if;
    select count(*) into remaining from public.couple_members where couple_id = membership.couple_id;
  end if;
  delete from auth.users where id = auth.uid();
end;
$$;

revoke all on function public.leave_couple() from public;
revoke all on function public.delete_my_account() from public;
grant execute on function public.leave_couple() to authenticated;
grant execute on function public.delete_my_account() to authenticated;
