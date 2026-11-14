-- LIVE SNAPSHOT of app_private.guard_invite_update on vowmukhhnfhtnjlswkun.
-- Read on 2026-11-14 with pg_get_functiondef. Do not apply except as rollback.

CREATE OR REPLACE FUNCTION app_private.guard_invite_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'app_private'
AS $function$
begin
  if new.id is distinct from old.id
    or new.couple_id is distinct from old.couple_id
    or new.created_by is distinct from old.created_by
    or new.token_hash is distinct from old.token_hash
    or new.expires_at is distinct from old.expires_at
  then
    raise exception 'forbidden';
  end if;

  if new.redeemed_at is distinct from old.redeemed_at
    or new.redeemed_by is distinct from old.redeemed_by
  then
    if not exists (
      select 1 from app_private.internal_ops
      where couple_id = new.couple_id and op = 'redeem'
    ) then
      raise exception 'forbidden';
    end if;
  end if;

  if old.revoked_at is not null and new.revoked_at is distinct from old.revoked_at then
    raise exception 'forbidden';
  end if;

  return new;
end;
$function$;
