-- NOT APPLIED. Apply this before deploying send-push from this proposal.
--
-- Each account stores the language its pushes should use. The client writes
-- en or he for itself. send-push reads the recipient's row with the service
-- role, which bypasses RLS. A missing row stays English.

create table if not exists public.profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  lang text not null default 'en' check (lang in ('en', 'he')),
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles
  for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists profiles_insert_own on public.profiles;
create policy profiles_insert_own on public.profiles
  for insert
  to authenticated
  with check (auth.uid() = user_id);

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

grant select, insert, update on public.profiles to authenticated;
