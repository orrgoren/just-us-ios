-- Not applied. Orr applies this separately. Do not run it on the live project.
-- Numbered 017. 014 is the applied mood policy. 015 and 016 are the chat pull request.
--
-- A new draft's planner is the other member after the last completed or
-- scheduled date. A skip does not move the turn. With no finished night,
-- member_index 0 plans first. ensure_active_draft can keep inserting the
-- row; this trigger is what the planner becomes.

create or replace function public.next_planner_user_id(p_couple_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  with last_night as (
    select planner_user_id
    from public.dates
    where couple_id = p_couple_id
      and status in ('completed', 'scheduled')
    order by scheduled_at desc nulls last, created_at desc
    limit 1
  )
  select coalesce(
    (
      select member.user_id
      from public.couple_members as member
      where member.couple_id = p_couple_id
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

create or replace function public.assign_draft_planner()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  next_id uuid;
begin
  if new.status is distinct from 'draft' then
    return new;
  end if;
  next_id := public.next_planner_user_id(new.couple_id);
  if next_id is not null then
    new.planner_user_id := next_id;
  end if;
  return new;
end;
$$;

drop trigger if exists dates_assign_planner on public.dates;
create trigger dates_assign_planner
  before insert on public.dates
  for each row execute function public.assign_draft_planner();

revoke all on function public.next_planner_user_id(uuid) from public;
revoke all on function public.assign_draft_planner() from public;
