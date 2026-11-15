-- LIVE SNAPSHOT of app_private.touch_mood and mood_votes_touch.
-- Already on the project. Recorded so the harness matches. Do not re-apply.
-- A mood update cannot move the vote to another date or another person.
-- That is what stops a vote from being rewritten onto a finished date.
-- 014_mood_update_using.sql repeats the date rule in the policy. It is not applied.

CREATE OR REPLACE FUNCTION app_private.touch_mood()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if new.date_id is distinct from old.date_id or new.user_id is distinct from old.user_id then
    raise exception 'forbidden';
  end if;
  new.updated_at := now();
  return new;
end;
$function$;

drop trigger if exists mood_votes_touch on public.mood_votes;
create trigger mood_votes_touch
  before update on public.mood_votes
  for each row execute function app_private.touch_mood();
