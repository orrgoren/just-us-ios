-- Proposed. Not applied. Do not run this on the live project until it is approved.
-- Numbered 012 because 009, 010, and 011 are open records of other live changes.
--
-- public.dates already lets the planner change public_teaser and outfit_hint
-- while the date stays scheduled. guard_date_update does not block those
-- columns, and dates_update only requires couple membership.
--
-- private_date_plans does not. plans_update requires status = 'draft', so a
-- scheduled date cannot change private_notes. This widens that policy to a
-- scheduled date that has not been revealed. The trigger lets a draft replace
-- idea_id and prepared_at, and freezes both once the date leaves draft.
-- search_path is public. auth.uid() and public.dates are schema-qualified.
-- The function calls no extension functions.

drop policy if exists plans_update on public.private_date_plans;

create policy plans_update on public.private_date_plans
for update to authenticated
using (
  public.is_date_planner(date_id)
  and exists (
    select 1
    from public.dates d
    where d.id = private_date_plans.date_id
      and d.planner_user_id = auth.uid()
      and (
        d.status = 'draft'
        or (d.status = 'scheduled' and d.revealed_at is null)
      )
  )
)
with check (
  public.is_date_planner(date_id)
  and exists (
    select 1
    from public.dates d
    where d.id = private_date_plans.date_id
      and d.planner_user_id = auth.uid()
      and (
        d.status = 'draft'
        or (d.status = 'scheduled' and d.revealed_at is null)
      )
  )
);

create or replace function app_private.guard_plan_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if new.date_id is distinct from old.date_id then
    raise exception 'forbidden';
  end if;

  select d.status
    into v_status
  from public.dates d
  where d.id = new.date_id;

  -- A draft can still replace the idea. Every later status keeps it.
  if v_status is distinct from 'draft' then
    if new.idea_id is distinct from old.idea_id
      or new.prepared_at is distinct from old.prepared_at
    then
      raise exception 'forbidden';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists plans_guard_update on public.private_date_plans;
create trigger plans_guard_update
before update on public.private_date_plans
for each row
execute function app_private.guard_plan_update();
