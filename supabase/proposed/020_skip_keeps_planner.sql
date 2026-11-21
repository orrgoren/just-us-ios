-- Proposed only. Do not apply this on the live project from CI.
-- Orr applies it after review. No edge function changes with it.
--
-- Replaces next_planner_user_id from 017. A completed or scheduled night
-- still hands the next draft to the other member. A skip keeps that night's
-- planner, including after a manual swap. Execute stays revoked from anon
-- and authenticated. assign_draft_planner is unchanged and still calls this.

create or replace function public.next_planner_user_id(p_couple_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  with last_night as (
    select planner_user_id, status
    from public.dates
    where couple_id = p_couple_id
      and status in ('completed', 'scheduled', 'skipped')
    order by scheduled_at desc nulls last, created_at desc
    limit 1
  )
  select coalesce(
    (
      select member.user_id
      from public.couple_members as member
      where member.couple_id = p_couple_id
        and (select status from last_night) = 'skipped'
        and member.user_id = (select planner_user_id from last_night)
      limit 1
    ),
    (
      select member.user_id
      from public.couple_members as member
      where member.couple_id = p_couple_id
        and (select status from last_night) is distinct from 'skipped'
        and (select planner_user_id from last_night) is not null
        and member.user_id is distinct from (select planner_user_id from last_night)
      order by member.member_index
      limit 1
    ),
    (
      select member.user_id
      from public.couple_members as member
      where member.couple_id = p_couple_id
      order by member.member_index
      limit 1
    )
  );
$$;

revoke all on function public.next_planner_user_id(uuid) from public, anon, authenticated;
revoke execute on function public.next_planner_user_id(uuid) from anon, authenticated;
