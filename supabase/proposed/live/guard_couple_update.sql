-- LIVE SNAPSHOT of app_private.guard_couple_update on vowmukhhnfhtnjlswkun.
-- Read on 2026-11-14 with pg_get_functiondef. Do not apply except as rollback.

CREATE OR REPLACE FUNCTION app_private.guard_couple_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.id is distinct from old.id or new.created_by is distinct from old.created_by or new.created_at is distinct from old.created_at then
    raise exception 'forbidden';
  end if;
  if new.weekday < 0 or new.weekday > 6 then
    raise exception 'invalid_weekday';
  end if;
  if new.default_duration_minutes < 30 or new.default_duration_minutes > 360 then
    raise exception 'invalid_duration';
  end if;
  if new.timezone !~ '^[A-Za-z0-9_+\\-/]{1,80}$' then
    raise exception 'invalid_timezone';
  end if;
  begin
    perform public.next_weekly_instant(new.weekday, new.local_time, new.timezone, now());
  exception
    when invalid_parameter_value then
      raise exception 'invalid_timezone';
  end;
  new.updated_at := now();
  return new;
end;
$function$;
