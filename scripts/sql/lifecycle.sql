-- Isolated checks for the proposed SQL. The harness and proposed files are
-- loaded first. This never connects to the live project.

create trigger dates_guard before update on public.dates
for each row execute function app_private.guard_date_update();

create trigger couples_guard before update on public.couples
for each row execute function app_private.guard_couple_update();

create trigger invites_guard before update on public.couple_invites
for each row execute function app_private.guard_invite_update();

create trigger notes_guard before update on public.memory_notes
for each row execute function app_private.touch_memory();

alter table public.couples enable row level security;
create policy couple_isolation on public.couples
  for select to authenticated
  using (
    exists (
      select 1 from public.couple_members as member
      where member.couple_id = couples.id and member.user_id = auth.uid()
    )
  );

insert into auth.users (id) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc'),
  ('dddddddd-dddd-4ddd-8ddd-dddddddddddd'),
  ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'),
  ('ffffffff-ffff-4fff-8fff-ffffffffffff');

insert into public.couples (id, created_by, weekday, local_time, timezone, default_duration_minutes, invitee_display_name) values
  ('11111111-1111-4111-8111-111111111111', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 4, '20:30', 'Asia/Jerusalem', 90, 'Blair'),
  ('22222222-2222-4222-8222-222222222222', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 4, '20:30', 'Asia/Jerusalem', 90, 'Drew'),
  ('33333333-3333-4333-8333-333333333333', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', 4, '20:30', 'Asia/Jerusalem', 90, 'Fran');

insert into public.couple_members (couple_id, user_id, display_name, member_index) values
  ('11111111-1111-4111-8111-111111111111', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'Alex', 0),
  ('11111111-1111-4111-8111-111111111111', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'Blair', 1),
  ('22222222-2222-4222-8222-222222222222', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'Casey', 0),
  ('22222222-2222-4222-8222-222222222222', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'Drew', 1),
  ('33333333-3333-4333-8333-333333333333', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', 'Eden', 0),
  ('33333333-3333-4333-8333-333333333333', 'ffffffff-ffff-4fff-8fff-ffffffffffff', 'Fran', 1);

insert into public.dates (
  id, couple_id, planner_user_id, status, scheduled_at, location
) values
  ('aaaa1111-1111-4111-8111-111111111111', '11111111-1111-4111-8111-111111111111', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'scheduled', now(), 'home'),
  ('cccc2222-2222-4222-8222-222222222222', '22222222-2222-4222-8222-222222222222', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'scheduled', now(), 'home'),
  ('eeee3333-3333-4333-8333-333333333333', '33333333-3333-4333-8333-333333333333', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', 'scheduled', now(), 'home');

insert into public.private_date_plans (date_id, idea_id) values
  ('aaaa1111-1111-4111-8111-111111111111', 'h1'),
  ('cccc2222-2222-4222-8222-222222222222', 'h1'),
  ('eeee3333-3333-4333-8333-333333333333', 'h1');

insert into public.memory_notes (id, date_id, author_user_id, note) values
  ('a1111111-1111-4111-8111-111111111111', 'cccc2222-2222-4222-8222-222222222222', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'Kept');

insert into storage.objects (bucket_id, name) values
  ('date-photos', '11111111-1111-4111-8111-111111111111/aaaa1111-1111-4111-8111-111111111111.jpg');

-- The harness trigger matches live storage.protect_delete. A direct delete
-- raises 42501 and leaves the row in place.
do $$
begin
  delete from storage.objects where bucket_id = 'date-photos';
  raise exception 'storage_delete_was_allowed';
exception
  when insufficient_privilege then
    null;
end $$;

do $$
begin
  if not exists (
    select 1 from storage.objects
    where name = '11111111-1111-4111-8111-111111111111/aaaa1111-1111-4111-8111-111111111111.jpg'
  ) then
    raise exception 'storage_row_disappeared';
  end if;
end $$;

-- A client-set GUC cannot reassign created_by.
do $$
begin
  perform set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', false);
  perform set_config('app.membership_handoff', 'on', false);
  update public.couples
  set created_by = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
  where id = '11111111-1111-4111-8111-111111111111';
  raise exception 'guc_without_ticket_was_accepted';
exception
  when others then
    if sqlerrm = 'guc_without_ticket_was_accepted' then
      raise;
    end if;
    if sqlerrm <> 'forbidden' then
      raise;
    end if;
end $$;

select set_config('app.membership_handoff', '', false);

-- Couple isolation under RLS. The owner bypasses it, so this runs as authenticated.
grant select on public.couple_members to authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', false);
set role authenticated;
do $$
declare
  seen int;
begin
  select count(*) into seen from public.couples;
  if seen <> 1 then
    raise exception 'couple_isolation_failed:%', seen;
  end if;
end $$;
reset role;

-- A unlinks. The whole couple goes. B is told. Neither login is deleted.
-- The photo row stays, because SQL cannot delete storage.objects.
-- The return value is only the couple that was closed. Couple 222 still
-- exists, so its photos are not eligible for deletion.
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', false);
create temporary table leave_closed (id uuid);
insert into leave_closed select public.leave_couple();

do $$
begin
  if exists (select 1 from public.couples where id = '11111111-1111-4111-8111-111111111111') then
    raise exception 'couple_remained_after_leave';
  end if;
  if exists (select 1 from public.dates where id = 'aaaa1111-1111-4111-8111-111111111111') then
    raise exception 'night_remained_after_leave';
  end if;
  if exists (select 1 from public.couple_members where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') then
    raise exception 'leaver_still_a_member';
  end if;
  if not exists (select 1 from auth.users where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') then
    raise exception 'leave_deleted_the_user';
  end if;
  if not exists (
    select 1 from public.space_closures where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
  ) then
    raise exception 'partner_was_not_told';
  end if;
  if not exists (
    select 1 from storage.objects
    where name = '11111111-1111-4111-8111-111111111111/aaaa1111-1111-4111-8111-111111111111.jpg'
  ) then
    raise exception 'sql_removed_the_photo';
  end if;
  if (select count(*) from leave_closed) <> 1
     or not exists (
       select 1 from leave_closed where id = '11111111-1111-4111-8111-111111111111'
     )
  then
    raise exception 'leave_returned_the_wrong_couples';
  end if;
  if exists (
    select 1 from app_private.closed_couples
    where couple_id <> '11111111-1111-4111-8111-111111111111'
  ) then
    raise exception 'closed_couples_recorded_an_extra_id';
  end if;
  if not app_private.photo_delete_allowed('11111111-1111-4111-8111-111111111111') then
    raise exception 'closed_couple_photo_not_allowed';
  end if;
  if app_private.photo_delete_allowed('22222222-2222-4222-8222-222222222222') then
    raise exception 'living_couple_photo_was_allowed';
  end if;
  if exists (
    select 1 from pg_proc as proc
    join pg_namespace as nsp on nsp.oid = proc.pronamespace
    where nsp.nspname = 'public' and proc.proname = 'couples_touching_me'
  ) then
    raise exception 'couples_touching_me_still_exists';
  end if;
end $$;

-- B's couple is already gone. Deleting the account removes B's login only.
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', false);
select public.delete_my_account();

do $$
begin
  if exists (select 1 from auth.users where id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb') then
    raise exception 'last_member_was_not_deleted';
  end if;
  if not exists (select 1 from auth.users where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') then
    raise exception 'unlinked_user_was_deleted';
  end if;
  if not exists (
    select 1 from storage.objects
    where name = '11111111-1111-4111-8111-111111111111/aaaa1111-1111-4111-8111-111111111111.jpg'
  ) then
    raise exception 'sql_removed_the_photo';
  end if;
end $$;

-- C deletes while D is still a partner. The couple and everything tied to it go.
-- D's login stays, with a notice for the next launch. The idea catalog stays.
insert into public.ideas (id, title_he) values ('h1', 'catalog');
insert into public.couple_invites (id, couple_id, created_by, token_hash, expires_at) values
  ('c2222222-2222-4222-8222-222222222222', '22222222-2222-4222-8222-222222222222', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'hash', now() + interval '1 day');
insert into public.device_tokens (user_id, token, platform) values
  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'token-c', 'ios'),
  ('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'token-d', 'ios');
insert into public.push_deliveries (recipient_user_id, kind, transactional) values
  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'planReady', true),
  ('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'weeklyReminder', false);
insert into public.push_outbox (caller_user_id, recipient_user_id, kind, not_before) values
  ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'planReady', now());
insert into storage.objects (bucket_id, name) values
  ('date-photos', '22222222-2222-4222-8222-222222222222/cccc2222-2222-4222-8222-222222222222.jpg');
insert into public.import_fingerprints (couple_id, fingerprint) values
  ('22222222-2222-4222-8222-222222222222', 'fp');
insert into app_private.internal_ops (couple_id, op) values
  ('22222222-2222-4222-8222-222222222222', 'redeem');

select set_config('request.jwt.claim.sub', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', false);
select public.delete_my_account();

do $$
declare
  closed uuid;
begin
  if exists (select 1 from public.couples where id = '22222222-2222-4222-8222-222222222222') then
    raise exception 'couple_remained_after_partner_delete';
  end if;
  if exists (select 1 from public.dates where id = 'cccc2222-2222-4222-8222-222222222222') then
    raise exception 'scheduled_date_remained';
  end if;
  if exists (select 1 from public.private_date_plans where date_id = 'cccc2222-2222-4222-8222-222222222222') then
    raise exception 'planned_idea_remained';
  end if;
  if exists (select 1 from public.memory_notes where id = 'a1111111-1111-4111-8111-111111111111') then
    raise exception 'memory_remained';
  end if;
  if exists (select 1 from public.couple_invites where couple_id = '22222222-2222-4222-8222-222222222222') then
    raise exception 'invite_remained';
  end if;
  if exists (select 1 from public.import_fingerprints where couple_id = '22222222-2222-4222-8222-222222222222') then
    raise exception 'fingerprint_remained';
  end if;
  if exists (select 1 from app_private.internal_ops where couple_id = '22222222-2222-4222-8222-222222222222') then
    raise exception 'internal_op_remained';
  end if;
  if not exists (select 1 from storage.objects where name like '22222222-2222-4222-8222-222222222222/%') then
    raise exception 'sql_removed_the_photo';
  end if;
  if exists (select 1 from public.device_tokens where token in ('token-c', 'token-d')) then
    raise exception 'push_device_remained';
  end if;
  if exists (
    select 1 from public.push_deliveries
    where recipient_user_id in (
      'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
    )
  ) then
    raise exception 'push_delivery_remained';
  end if;
  if exists (select 1 from public.push_outbox) then
    raise exception 'pending_push_remained';
  end if;
  if not exists (select 1 from public.ideas where id = 'h1') then
    raise exception 'idea_catalog_was_deleted';
  end if;
  if exists (select 1 from auth.users where id = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc') then
    raise exception 'departing_user_remained';
  end if;
  if not exists (select 1 from auth.users where id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd') then
    raise exception 'partner_was_deleted';
  end if;
  select user_id into closed from public.space_closures
  where user_id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
  if closed is null then
    raise exception 'partner_was_not_told';
  end if;
end $$;

-- Calling delete again, with the same login already gone, does not raise.
select set_config('request.jwt.claim.sub', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', false);
select public.delete_my_account();

do $$
begin
  if not exists (select 1 from auth.users where id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd') then
    raise exception 'repeat_delete_removed_the_partner';
  end if;
end $$;

-- Both members leave. No empty couple row remains.
select set_config('request.jwt.claim.sub', 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', false);
select public.leave_couple();
select set_config('request.jwt.claim.sub', 'ffffffff-ffff-4fff-8fff-ffffffffffff', false);
select public.leave_couple();

do $$
begin
  if exists (select 1 from public.couples where id = '33333333-3333-4333-8333-333333333333') then
    raise exception 'empty_couple_remained';
  end if;
  if not exists (select 1 from auth.users where id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee') then
    raise exception 'leave_deleted_the_user';
  end if;
  if exists (
    select 1 from app_private.internal_ops
    where couple_id = '00000000-0000-4000-8000-000000000099'
  ) then
    raise exception 'orphan_internal_op_remained';
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'internal_ops_couple_id_fkey'
  ) then
    raise exception 'internal_ops_fk_missing';
  end if;
end $$;

-- Sam created an older couple and is a member of a current one.
-- leave_couple closes only the current couple. The older couple, and its
-- photo, stay. closed_couple_ids does not list the older couple.
insert into auth.users (id) values
  ('40404040-4040-4040-8040-404040404040'),
  ('50505050-5050-4050-8050-505050505050'),
  ('60606060-6060-4060-8060-606060606060');
insert into public.couples (id, created_by, weekday, local_time, timezone, default_duration_minutes, invitee_display_name) values
  ('04040404-0404-4040-8040-040404040404', '40404040-4040-4040-8040-404040404040', 4, '20:30', 'Asia/Jerusalem', 90, 'Old'),
  ('05050505-0505-4050-8050-050505050505', '40404040-4040-4040-8040-404040404040', 4, '20:30', 'Asia/Jerusalem', 90, 'Now');
insert into public.couple_members (couple_id, user_id, display_name, member_index) values
  ('04040404-0404-4040-8040-040404040404', '50505050-5050-4050-8050-505050505050', 'Old', 0),
  ('05050505-0505-4050-8050-050505050505', '40404040-4040-4040-8040-404040404040', 'Sam', 0),
  ('05050505-0505-4050-8050-050505050505', '60606060-6060-4060-8060-606060606060', 'Now', 1);
insert into storage.objects (bucket_id, name) values
  ('date-photos', '04040404-0404-4040-8040-040404040404/keep.jpg');

select set_config('request.jwt.claim.sub', '40404040-4040-4040-8040-404040404040', false);
create temporary table sam_closed (id uuid);
insert into sam_closed select public.leave_couple();

do $$
begin
  if (select count(*) from sam_closed) <> 1
     or not exists (select 1 from sam_closed where id = '05050505-0505-4050-8050-050505050505')
  then
    raise exception 'leave_returned_an_old_couple';
  end if;
  if not exists (select 1 from public.couples where id = '04040404-0404-4040-8040-040404040404') then
    raise exception 'older_couple_was_closed_by_leave';
  end if;
  if app_private.photo_delete_allowed('04040404-0404-4040-8040-040404040404') then
    raise exception 'older_couple_photo_was_allowed';
  end if;
  if not app_private.photo_delete_allowed('05050505-0505-4050-8050-050505050505') then
    raise exception 'current_couple_photo_not_allowed';
  end if;
  if exists (
    select 1 from public.closed_couple_ids()
    where closed_couple_ids <> '05050505-0505-4050-8050-050505050505'
  ) or (select count(*) from public.closed_couple_ids()) <> 1
  then
    raise exception 'closed_couple_ids_leaked';
  end if;
  if not exists (
    select 1 from storage.objects
    where name = '04040404-0404-4040-8040-040404040404/keep.jpg'
  ) then
    raise exception 'sql_removed_the_photo';
  end if;
end $$;

do $$
begin
  if public.photo_delete_allowed('04040404-0404-4040-8040-040404040404') then
    raise exception 'public_photo_delete_allowed_a_living_couple';
  end if;
  if not public.photo_delete_allowed('05050505-0505-4050-8050-050505050505') then
    raise exception 'public_photo_delete_allowed_missed_a_closed_couple';
  end if;
  if has_function_privilege('authenticated', 'public.photo_delete_allowed(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.closed_couples_pending(integer)', 'execute')
     or has_function_privilege('authenticated', 'public.ack_swept_couples(uuid[])', 'execute')
  then
    raise exception 'sweep_functions_granted_to_authenticated';
  end if;
  if not exists (
       select 1 from public.closed_couples_pending(50) as pending(couple_id)
       where couple_id = '05050505-0505-4050-8050-050505050505'
     )
     or exists (
       select 1 from public.closed_couples_pending(50) as pending(couple_id)
       where couple_id = '04040404-0404-4040-8040-040404040404'
     )
  then
    raise exception 'pending_sweep_missed_the_closed_couple';
  end if;
end $$;

-- Live PostgREST sets this JSON and leaves request.jwt.claim.role unset.
select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"40404040-4040-4040-8040-404040404040"}',
  false
);
do $$
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') <> '' then
    raise exception 'fixture_set_the_old_role_guc';
  end if;
  if coalesce(auth.role(), '') is distinct from 'authenticated' then
    raise exception 'auth_role_missed_the_claims_json';
  end if;
  begin
    perform public.ack_swept_couples(array['05050505-0505-4050-8050-050505050505']::uuid[]);
    raise exception 'user_swept_a_couple';
  exception
    when others then
      if sqlerrm <> 'forbidden' then
        raise;
      end if;
  end;
end $$;

select set_config(
  'request.jwt.claims',
  '{"role":"service_role","sub":"40404040-4040-4040-8040-404040404040"}',
  false
);
do $$
begin
  if coalesce(auth.role(), '') is distinct from 'service_role' then
    raise exception 'auth_role_missed_the_service_role_claim';
  end if;
end $$;
select public.ack_swept_couples(array['05050505-0505-4050-8050-050505050505']::uuid[]);

do $$
begin
  if exists (select 1 from app_private.closed_couples where couple_id = '05050505-0505-4050-8050-050505050505') then
    raise exception 'sweep_left_the_closed_couple';
  end if;
end $$;

insert into app_private.closed_couples (couple_id, closed_by)
values ('05050505-0505-4050-8050-050505050505', '40404040-4040-4040-8040-404040404040');
select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"40404040-4040-4040-8040-404040404040"}',
  false
);
select public.ack_closed_couples(array['05050505-0505-4050-8050-050505050505']::uuid[]);

do $$
begin
  if exists (select 1 from public.closed_couple_ids()) then
    raise exception 'ack_left_a_closed_couple';
  end if;
end $$;

-- Q already left an older couple the way the live function does: membership
-- is gone, but the note, the mood vote, and created_by still point at Q.
-- Q is now in a new couple with R. Deleting Q closes both couples. P and R
-- keep their logins and get the notice. author_user_id stays NOT NULL.
insert into auth.users (id) values
  ('10101010-1010-4010-8010-101010101010'),
  ('20202020-2020-4020-8020-202020202020'),
  ('30303030-3030-4030-8030-303030303030');

insert into public.couples (id, created_by, weekday, local_time, timezone, default_duration_minutes, invitee_display_name) values
  ('01010101-0101-4010-8010-010101010101', '20202020-2020-4020-8020-202020202020', 4, '20:30', 'Asia/Jerusalem', 90, 'Pat'),
  ('02020202-0202-4020-8020-020202020202', '20202020-2020-4020-8020-202020202020', 4, '20:30', 'Asia/Jerusalem', 90, 'Rae');

insert into public.couple_members (couple_id, user_id, display_name, member_index) values
  ('01010101-0101-4010-8010-010101010101', '10101010-1010-4010-8010-101010101010', 'Pat', 0),
  ('02020202-0202-4020-8020-020202020202', '20202020-2020-4020-8020-202020202020', 'Quinn', 0),
  ('02020202-0202-4020-8020-020202020202', '30303030-3030-4030-8030-303030303030', 'Rae', 1);

insert into public.dates (id, couple_id, planner_user_id, status, scheduled_at, location) values
  ('0101aaaa-0101-4010-8010-010101010101', '01010101-0101-4010-8010-010101010101', '20202020-2020-4020-8020-202020202020', 'completed', now(), 'home');

insert into public.memory_notes (id, date_id, author_user_id, note) values
  ('0101bbbb-0101-4010-8010-010101010101', '0101aaaa-0101-4010-8010-010101010101', '20202020-2020-4020-8020-202020202020', 'Old note');

insert into public.mood_votes (date_id, user_id, mood) values
  ('0101aaaa-0101-4010-8010-010101010101', '20202020-2020-4020-8020-202020202020', 'romance');

insert into storage.objects (bucket_id, name) values
  ('date-photos', '01010101-0101-4010-8010-010101010101/old.jpg');

select set_config('request.jwt.claim.sub', '20202020-2020-4020-8020-202020202020', false);
select public.delete_my_account();

do $$
begin
  if exists (select 1 from auth.users where id = '20202020-2020-4020-8020-202020202020') then
    raise exception 'ex_partner_was_not_deleted';
  end if;
  if exists (select 1 from public.couples where id in (
    '01010101-0101-4010-8010-010101010101',
    '02020202-0202-4020-8020-020202020202'
  )) then
    raise exception 'ex_partner_couple_remained';
  end if;
  if exists (select 1 from public.memory_notes where author_user_id = '20202020-2020-4020-8020-202020202020') then
    raise exception 'ex_partner_note_remained';
  end if;
  if exists (select 1 from public.mood_votes where user_id = '20202020-2020-4020-8020-202020202020') then
    raise exception 'ex_partner_mood_remained';
  end if;
  if not exists (select 1 from auth.users where id = '10101010-1010-4010-8010-101010101010') then
    raise exception 'old_partner_was_deleted';
  end if;
  if not exists (select 1 from auth.users where id = '30303030-3030-4030-8030-303030303030') then
    raise exception 'new_partner_was_deleted';
  end if;
  if not exists (
    select 1 from public.space_closures
    where user_id in (
      '10101010-1010-4010-8010-101010101010',
      '30303030-3030-4030-8030-303030303030'
    )
    having count(*) = 2
  ) then
    raise exception 'ex_partner_notices_missing';
  end if;
  if not exists (
    select 1 from storage.objects where name = '01010101-0101-4010-8010-010101010101/old.jpg'
  ) then
    raise exception 'sql_removed_the_photo';
  end if;
  if not exists (
    select 1 from pg_attribute
    where attrelid = 'public.memory_notes'::regclass
      and attname = 'author_user_id'
      and attnotnull
  ) then
    raise exception 'author_user_id_became_nullable';
  end if;
end $$;

do $$
begin
  if position('for update' in pg_get_functiondef('public.leave_couple()'::regprocedure)) = 0 then
    raise exception 'leave_has_no_membership_lock';
  end if;
end $$;

-- 012. A scheduled, unrevealed plan can change private notes. The idea and
-- prepared_at stay put until the date is a draft again. After reveal the
-- policy matches nothing, so the update changes zero rows.
do $$
declare
  n int;
  target_date uuid := '34343434-3434-4434-8434-343434343434';
  planner uuid := '10101010-1010-4010-8010-101010101010';
  partner uuid := '30303030-3030-4030-8030-303030303030';
  couple uuid := '12121212-1212-4212-8212-121212121212';
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'private_date_plans'
      and column_name = 'prepared_at'
  ) then
    raise exception 'prepared_at_missing';
  end if;

  alter table public.private_date_plans enable row level security;
  grant update on public.private_date_plans to authenticated;
  -- UPDATE also has to pass SELECT policies. Live already has one. This
  -- throwaway policy only makes the row visible so plans_update is what decides.
  create policy plans_select_test on public.private_date_plans
    for select to authenticated
    using (true);

  insert into public.couples (
    id, created_by, weekday, local_time, timezone, default_duration_minutes, invitee_display_name
  ) values (
    couple, planner, 4, '20:30', 'Asia/Jerusalem', 90, 'Blair'
  );
  insert into public.couple_members (couple_id, user_id, display_name, member_index) values
    (couple, planner, 'Alex', 0),
    (couple, partner, 'Rae', 1);
  insert into public.dates (
    id, couple_id, planner_user_id, status, scheduled_at, location
  ) values (
    target_date, couple, planner, 'scheduled', timestamptz '2026-11-19 18:30:00+00', 'home'
  );
  insert into public.private_date_plans (date_id, idea_id, private_notes, prepared_at) values (
    target_date, 'h1', 'old', timestamptz '2026-11-15 18:00:00+00'
  );

  perform set_config('request.jwt.claim.sub', planner::text, true);
  execute 'set local role authenticated';

  update public.private_date_plans
    set private_notes = 'still editable'
    where date_id = target_date;
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'scheduled_notes_not_updated';
  end if;
  if exists (
    select 1 from public.private_date_plans
    where date_id = target_date and idea_id is distinct from 'h1'
  ) then
    raise exception 'scheduled_note_edit_moved_the_idea';
  end if;

  begin
    update public.private_date_plans
      set idea_id = 'h9'
      where date_id = target_date;
    raise exception 'scheduled_idea_change_was_allowed';
  exception
    when others then
      if sqlerrm <> 'forbidden' then
        raise;
      end if;
  end;

  begin
    update public.private_date_plans
      set prepared_at = timestamptz '2026-11-15 21:00:00+00'
      where date_id = target_date;
    raise exception 'scheduled_prepared_at_change_was_allowed';
  exception
    when others then
      if sqlerrm <> 'forbidden' then
        raise;
      end if;
  end;

  execute 'reset role';
  update public.dates
    set status = 'draft', revealed_at = null
    where id = target_date;
  perform set_config('request.jwt.claim.sub', planner::text, true);
  execute 'set local role authenticated';

  update public.private_date_plans
    set idea_id = 'h2',
        prepared_at = timestamptz '2026-11-15 19:00:00+00'
    where date_id = target_date;
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'draft_idea_change_blocked';
  end if;

  execute 'reset role';
  update public.dates
    set status = 'scheduled', revealed_at = null
    where id = target_date;
  perform set_config('request.jwt.claim.sub', partner::text, true);
  execute 'set local role authenticated';

  update public.private_date_plans
    set private_notes = 'not the planner'
    where date_id = target_date;
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'partner_notes_updated';
  end if;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', planner::text, true);
  update public.dates
    set revealed_at = timestamptz '2026-11-15 20:00:00+00'
    where id = target_date;
  execute 'set local role authenticated';

  update public.private_date_plans
    set private_notes = 'too late'
    where date_id = target_date;
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'revealed_notes_updated';
  end if;

  execute 'reset role';
end $$;

-- 013. A member can set, change, and remove their own mood while the date is
-- scheduled and still unrevealed. Reveal, a completed date, and someone
-- else's row do not.
do $$
declare
  n int;
  target_date uuid := '56565656-5656-4656-8656-565656565656';
  planner uuid := '10101010-1010-4010-8010-101010101010';
  partner uuid := '30303030-3030-4030-8030-303030303030';
  outsider uuid := '50505050-5050-4050-8050-505050505050';
  couple uuid := '12121212-1212-4212-8212-121212121212';
begin
  insert into auth.users (id) values (outsider) on conflict do nothing;
  -- Live Supabase lets authenticated call auth.uid(). The throwaway role
  -- does not, and is_couple_member is not security definer.
  grant usage on schema auth to authenticated;
  grant execute on function auth.uid() to authenticated;
  insert into public.dates (
    id, couple_id, planner_user_id, status, scheduled_at, location
  ) values (
    target_date, couple, planner, 'scheduled', timestamptz '2026-11-19 18:30:00+00', 'home'
  );

  alter table public.mood_votes enable row level security;
  grant select, insert, update, delete on public.mood_votes to authenticated;
  create policy mood_votes_select_test on public.mood_votes
    for select to authenticated
    using (true);

  perform set_config('request.jwt.claim.sub', planner::text, true);
  execute 'set local role authenticated';

  insert into public.mood_votes (date_id, user_id, mood)
  values (target_date, planner, 'fun');
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'scheduled_mood_not_inserted';
  end if;

  update public.mood_votes
    set mood = 'chill'
    where date_id = target_date and user_id = planner;
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'scheduled_mood_not_updated';
  end if;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', partner::text, true);
  execute 'set local role authenticated';

  update public.mood_votes
    set mood = 'deep'
    where date_id = target_date and user_id = planner;
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'partner_changed_the_other_mood';
  end if;

  insert into public.mood_votes (date_id, user_id, mood)
  values (target_date, partner, 'romance');
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'partner_mood_not_inserted';
  end if;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', outsider::text, true);
  execute 'set local role authenticated';
  begin
    insert into public.mood_votes (date_id, user_id, mood)
    values (target_date, outsider, 'fun');
    raise exception 'outsider_mood_was_allowed';
  exception
    when insufficient_privilege then
      null;
  end;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', planner::text, true);
  update public.dates
    set status = 'draft', revealed_at = null
    where id = target_date;
  execute 'set local role authenticated';
  update public.mood_votes
    set mood = 'deep'
    where date_id = target_date and user_id = planner;
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'draft_mood_not_updated';
  end if;

  begin
    update public.mood_votes
      set date_id = '99999999-9999-4999-8999-999999999999'
      where date_id = target_date and user_id = planner;
    raise exception 'mood_date_change_was_allowed';
  exception
    when others then
      if sqlerrm is distinct from 'forbidden' then
        raise;
      end if;
  end;

  delete from public.mood_votes
    where date_id = target_date and user_id = planner;
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'draft_mood_not_deleted';
  end if;

  execute 'reset role';
  insert into public.private_date_plans (date_id, idea_id, private_notes)
  values (target_date, 'h1', 'mood test')
  on conflict (date_id) do nothing;
  perform set_config('request.jwt.claim.sub', planner::text, true);
  update public.dates
    set status = 'scheduled', revealed_at = null
    where id = target_date;
  execute 'set local role authenticated';
  insert into public.mood_votes (date_id, user_id, mood)
  values (target_date, planner, 'fun');

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', planner::text, true);
  update public.dates
    set revealed_at = timestamptz '2026-11-15 20:00:00+00'
    where id = target_date;
  execute 'set local role authenticated';
  update public.mood_votes
    set mood = 'adventure'
    where date_id = target_date and user_id = planner;
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'revealed_mood_was_allowed';
  end if;

  delete from public.mood_votes
    where date_id = target_date and user_id = planner;
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'revealed_mood_was_deleted';
  end if;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', planner::text, true);
  update public.dates
    set status = 'completed'
    where id = target_date;
  execute 'set local role authenticated';
  update public.mood_votes
    set mood = 'fun'
    where date_id = target_date and user_id = planner;
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'completed_mood_was_allowed';
  end if;

  execute 'reset role';
end $$;

-- 017. A new draft takes the other member after the last completed or
-- scheduled night. A skip leaves that turn alone. Not applied live.
insert into auth.users (id) values
  ('61616161-6161-4161-8161-616161616161'),
  ('62626262-6262-4262-8262-626262626262');

insert into public.couples (
  id, created_by, weekday, local_time, timezone, default_duration_minutes, invitee_display_name
) values (
  '63636363-6363-4363-8363-636363636363',
  '61616161-6161-4161-8161-616161616161',
  4, '20:30', 'Asia/Jerusalem', 90, 'Blair'
);

insert into public.couple_members (couple_id, user_id, display_name, member_index) values
  ('63636363-6363-4363-8363-636363636363', '61616161-6161-4161-8161-616161616161', 'Alex', 0),
  ('63636363-6363-4363-8363-636363636363', '62626262-6262-4262-8262-626262626262', 'Blair', 1);

insert into public.dates (id, couple_id, planner_user_id, status, scheduled_at, location) values
  (
    '64646464-6464-4464-8464-646464646464',
    '63636363-6363-4363-8363-636363636363',
    '62626262-6262-4262-8262-626262626262',
    'draft',
    '2026-10-22 18:30:00+00',
    'home'
  );

do $$
begin
  if (
    select planner_user_id from public.dates where id = '64646464-6464-4464-8464-646464646464'
  ) is distinct from '61616161-6161-4161-8161-616161616161' then
    raise exception 'first_draft_not_member_zero';
  end if;
end $$;

delete from public.dates where id = '64646464-6464-4464-8464-646464646464';

insert into public.dates (id, couple_id, planner_user_id, status, scheduled_at, location) values
  (
    '65656565-6565-4565-8565-656565656565',
    '63636363-6363-4363-8363-636363636363',
    '61616161-6161-4161-8161-616161616161',
    'completed',
    '2026-10-29 18:30:00+00',
    'home'
  );

insert into public.dates (id, couple_id, planner_user_id, status, scheduled_at, location) values
  (
    '66666666-6666-4666-8666-666666666666',
    '63636363-6363-4363-8363-636363636363',
    '61616161-6161-4161-8161-616161616161',
    'draft',
    '2026-11-19 18:30:00+00',
    'home'
  );

do $$
begin
  if (
    select planner_user_id from public.dates where id = '66666666-6666-4666-8666-666666666666'
  ) is distinct from '62626262-6262-4262-8262-626262626262' then
    raise exception 'draft_did_not_alternate';
  end if;
end $$;

delete from public.dates where id = '66666666-6666-4666-8666-666666666666';

insert into public.dates (id, couple_id, planner_user_id, status, scheduled_at, location) values
  (
    '67676767-6767-4676-8676-676767676767',
    '63636363-6363-4363-8363-636363636363',
    '61616161-6161-4161-8161-616161616161',
    'skipped',
    '2026-11-05 18:30:00+00',
    'home'
  );

insert into public.dates (id, couple_id, planner_user_id, status, scheduled_at, location) values
  (
    '68686868-6868-4686-8686-686868686868',
    '63636363-6363-4363-8363-636363636363',
    '61616161-6161-4161-8161-616161616161',
    'draft',
    '2026-11-19 18:30:00+00',
    'home'
  );

do $$
begin
  if (
    select planner_user_id from public.dates where id = '68686868-6868-4686-8686-686868686868'
  ) is distinct from '62626262-6262-4262-8262-626262626262' then
    raise exception 'skip_moved_the_turn';
  end if;
end $$;

delete from public.dates where id = '68686868-6868-4686-8686-686868686868';

insert into public.dates (id, couple_id, planner_user_id, status, scheduled_at, location) values
  (
    '69696969-6969-4696-8696-696969696969',
    '63636363-6363-4363-8363-636363636363',
    '62626262-6262-4262-8262-626262626262',
    'scheduled',
    '2026-11-12 18:30:00+00',
    'home'
  );

insert into public.dates (id, couple_id, planner_user_id, status, scheduled_at, location) values
  (
    '6a6a6a6a-6a6a-46a6-86a6-6a6a6a6a6a6a',
    '63636363-6363-4363-8363-636363636363',
    '62626262-6262-4262-8262-626262626262',
    'draft',
    '2026-11-19 18:30:00+00',
    'home'
  );

do $$
begin
  if (
    select planner_user_id from public.dates where id = '6a6a6a6a-6a6a-46a6-86a6-6a6a6a6a6a6a'
  ) is distinct from '61616161-6161-4161-8161-616161616161' then
    raise exception 'scheduled_night_did_not_hand_the_turn_on';
  end if;
end $$;
