-- PROPOSED ROLLBACK. Do not apply to vowmukhhnfhtnjlswkun unless Tom is
-- undoing 003, 004, and 006. CI does not run this file.
--
-- psql -f supabase/proposed/005_rollback.sql
-- from the repository root. The \ir lines restore the live function bodies
-- captured in supabase/proposed/live/. Then the drops remove only objects
-- those proposed files added.
--
-- author_name, memory_photo_path, device_tokens, notification_preferences,
-- and the date-photos bucket are already live. This file does not drop them.
-- Restoring author_user_id NOT NULL fails closed if a deletion already wrote
-- a null author. That is intentional.

\ir live/guard_date_update.sql
\ir live/touch_memory.sql
\ir live/guard_couple_update.sql
\ir live/guard_invite_update.sql
\ir live/leave_couple.sql

drop function if exists public.delete_my_account();
drop table if exists public.space_closures;
drop function if exists public.set_memory_photo_path(uuid, text);
drop function if exists public.claim_push_delivery(uuid, text, text);
drop function if exists app_private.delete_couple_photos(uuid);
drop function if exists app_private.begin_handoff();
drop function if exists app_private.end_handoff();
drop function if exists app_private.handoff_active();
drop table if exists app_private.handoff_tickets;
drop table if exists public.push_outbox;
drop table if exists public.push_deliveries;
alter table public.device_tokens drop column if exists environment;

-- Live column is NOT NULL. Run only after confirming no note was detached.
-- alter table public.memory_notes alter column author_user_id set not null;
