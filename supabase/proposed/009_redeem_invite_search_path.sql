-- Applied live as migration redeem_invite_search_path. Do not re-apply.
-- redeem_couple_invite calls digest(). pgcrypto is in the extensions schema.
-- A search_path of only public makes every redeem fail with 42883.
alter function public.redeem_couple_invite(text, boolean) set search_path = public, extensions;
