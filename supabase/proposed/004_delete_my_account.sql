-- PROPOSED ONLY. Do not apply until Tom verifies.
-- This file is not a migration. scripts/sql-lifecycle.sh runs it in CI.
--
-- Apply 002 and 003 first. 006 may be applied before or after this file.
-- The push deletes below run only when those tables exist.
--
-- If either partner deletes their account, every couple they still touch is
-- closed for both people: the couple row, dates, plans, notes, mood votes,
-- invites, import fingerprints, internal ops, both members' device tokens,
-- push deliveries, and pending push_outbox rows. The shared idea catalog
-- stays. The other person's login stays, with a space_closures row.
--
-- A person who already left under the live leave_couple still has notes,
-- mood votes, planned nights, or created_by pointing at the old couple.
-- Those foreign keys are NO ACTION and author_user_id is NOT NULL, so this
-- function closes each leftover couple instead of handing it off or nulling
-- the author. It does not drop NOT NULL. Photos are not deleted here. The
-- client calls delete-couple-photos before this RPC.
--
-- A second call, after the login is already gone, deletes nothing and
-- does not raise. Two deletes of the same couple take the couple row lock
-- in close_couple, in couple-id order.

create or replace function public.delete_my_account()
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

  for v_couple in
    select touched.id
    from app_private.couples_touched_by(v_uid) as touched(id)
    order by touched.id
  loop
    perform app_private.close_couple(v_couple, v_uid);
  end loop;

  -- Rows that no longer sit on a couple. These foreign keys are NO ACTION
  -- on live, and author_user_id cannot be nulled.
  delete from public.mood_votes where user_id = v_uid;
  delete from public.memory_notes where author_user_id = v_uid;
  delete from public.private_date_plans
  where date_id in (select id from public.dates where planner_user_id = v_uid);
  delete from public.dates where planner_user_id = v_uid;
  delete from public.couple_invites
  where created_by = v_uid or redeemed_by = v_uid;
  delete from public.couple_members where user_id = v_uid;
  delete from public.couples where created_by = v_uid;

  delete from auth.users where id = v_uid;
end;
$$;

revoke all on function public.delete_my_account() from public, anon, authenticated;
grant execute on function public.delete_my_account() to authenticated;
