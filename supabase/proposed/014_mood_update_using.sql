-- Applied live on 2026-11-16 as 20261116005108. Do not re-apply.
--
-- mood_votes_update USING only checked user_id = auth.uid(). WITH CHECK
-- looked at the new row, so a member could match their own vote and the
-- policy would judge the date they moved it to. The live trigger
-- mood_votes_touch already rejects a change of date_id or user_id, which
-- blocks moving a vote off a finished date. This policy is defense in depth:
-- the existing row also has to sit on a draft, or a scheduled date that is
-- not revealed, and the member still has to belong to that couple.

drop policy if exists mood_votes_update on public.mood_votes;

create policy mood_votes_update on public.mood_votes
for update to authenticated
using (
  user_id = auth.uid()
  and exists (
    select 1
    from public.dates as d
    where d.id = mood_votes.date_id
      and (
        d.status = 'draft'
        or (d.status = 'scheduled' and d.revealed_at is null)
      )
      and public.is_couple_member(d.couple_id)
  )
)
with check (
  user_id = auth.uid()
  and exists (
    select 1
    from public.dates as d
    where d.id = mood_votes.date_id
      and (
        d.status = 'draft'
        or (d.status = 'scheduled' and d.revealed_at is null)
      )
      and public.is_couple_member(d.couple_id)
  )
);
