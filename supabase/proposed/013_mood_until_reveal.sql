-- Not applied. Do not run this on the live project until it is approved.
-- Numbered 013 because 012 is already live.
--
-- mood_votes_insert, mood_votes_update, and mood_votes_delete let a member
-- change only their own mood, and only while the date is a draft. A scheduled
-- date rejected the write, so the app never reached send-push. A member can
-- keep that mood until the date is revealed. The user_id and
-- is_couple_member checks stay as they are.

drop policy if exists mood_votes_insert on public.mood_votes;
drop policy if exists mood_votes_update on public.mood_votes;
drop policy if exists mood_votes_delete on public.mood_votes;

create policy mood_votes_insert on public.mood_votes
for insert to authenticated
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

create policy mood_votes_update on public.mood_votes
for update to authenticated
using (user_id = auth.uid())
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

create policy mood_votes_delete on public.mood_votes
for delete to authenticated
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
);
