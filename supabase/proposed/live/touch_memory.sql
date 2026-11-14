-- LIVE SNAPSHOT of app_private.touch_memory on vowmukhhnfhtnjlswkun.
-- Read on 2026-11-14 with pg_get_functiondef. Do not apply except as rollback.
-- Live memory_notes.author_user_id is NOT NULL. 001's drop-not-null statement
-- was not applied.

CREATE OR REPLACE FUNCTION app_private.touch_memory()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.date_id is distinct from old.date_id or new.author_user_id is distinct from old.author_user_id or new.created_at is distinct from old.created_at then
    raise exception 'forbidden';
  end if;
  if char_length(btrim(new.note)) < 1 or char_length(new.note) > 2000 then
    raise exception 'note_too_long';
  end if;
  new.updated_at := now();
  return new;
end;
$function$;
