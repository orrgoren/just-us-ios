-- LIVE SNAPSHOT of public.leave_couple on vowmukhhnfhtnjlswkun.
-- Read on 2026-11-14 with pg_get_functiondef. Do not apply this to change
-- production. 005_rollback.sql runs it only to undo the proposed replacement.

CREATE OR REPLACE FUNCTION public.leave_couple()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  membership public.couple_members%rowtype;
  remaining int;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  select * into membership from public.couple_members where user_id = auth.uid();
  if not found then
    return;
  end if;
  delete from public.couple_members where user_id = auth.uid();
  select count(*) into remaining from public.couple_members where couple_id = membership.couple_id;
  if remaining = 0 then
    delete from public.couples where id = membership.couple_id;
  end if;
end;
$function$;
