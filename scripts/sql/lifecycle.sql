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

-- A client-set GUC is not a handoff ticket.
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

-- A unlinks. created_by moves to B. The unrevealed night is canceled.
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', false);
select public.leave_couple();

do $$
declare
  owner uuid;
  night text;
  plans int;
begin
  select created_by into owner from public.couples where id = '11111111-1111-4111-8111-111111111111';
  if owner <> 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' then
    raise exception 'created_by_stayed_on_leaver:%', owner;
  end if;
  select status into night from public.dates where id = 'aaaa1111-1111-4111-8111-111111111111';
  if night <> 'canceled' then
    raise exception 'unrevealed_not_canceled:%', night;
  end if;
  select count(*) into plans from public.private_date_plans where date_id = 'aaaa1111-1111-4111-8111-111111111111';
  if plans <> 0 then
    raise exception 'sealed_plan_survived_leave';
  end if;
  if exists (select 1 from public.couple_members where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') then
    raise exception 'leaver_still_a_member';
  end if;
end $$;

-- B, the last member, deletes. The couple and its photo go, even though B did not create it.
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', false);
select public.delete_my_account();

do $$
begin
  if exists (select 1 from public.couples where id = '11111111-1111-4111-8111-111111111111') then
    raise exception 'couple_remained_after_last_delete';
  end if;
  if exists (select 1 from auth.users where id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb') then
    raise exception 'last_member_was_not_deleted';
  end if;
  if not exists (select 1 from auth.users where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') then
    raise exception 'unlinked_user_was_deleted';
  end if;
  if exists (select 1 from storage.objects where bucket_id = 'date-photos') then
    raise exception 'date_photo_was_not_deleted';
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
  if exists (select 1 from storage.objects where name like '22222222-2222-4222-8222-222222222222/%') then
    raise exception 'couple_photo_remained';
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
  select user_id into closed from public.space_closures;
  if closed <> 'dddddddd-dddd-4ddd-8ddd-dddddddddddd' then
    raise exception 'partner_was_not_told:%', closed;
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
end $$;

do $$
begin
  if position('for update' in pg_get_functiondef('public.leave_couple()'::regprocedure)) = 0 then
    raise exception 'leave_has_no_membership_lock';
  end if;
end $$;
