-- Read-only. Paste this into the Supabase SQL editor on the live project.
-- It does not insert, update, delete, or change functions.
-- Do not apply supabase/proposed/003, 004, or 005 from this file.
--
-- confdeltype: a = NO ACTION, r = RESTRICT, c = CASCADE, n = SET NULL, d = SET DEFAULT.
-- Checked on vowmukhhnfhtnjlswkun on 2026-11-14. Public couple and date
-- children cascade. User columns on couples, invites, dates, notes, and
-- mood votes are NO ACTION. storage.objects has BEFORE DELETE
-- protect_objects_delete, which raises 42501.

select
  nsp.nspname as schema_name,
  rel.relname as table_name,
  con.conname as constraint_name,
  pg_get_constraintdef(con.oid) as definition,
  con.confdeltype as on_delete
from pg_constraint as con
join pg_class as rel on rel.oid = con.conrelid
join pg_namespace as nsp on nsp.oid = rel.relnamespace
where con.contype = 'f'
  and nsp.nspname in ('public', 'app_private', 'storage', 'auth')
order by 1, 2, 3;

select
  event_object_schema,
  event_object_table,
  trigger_name,
  action_timing,
  action_statement
from information_schema.triggers
where event_manipulation = 'DELETE'
  and event_object_schema in ('public', 'app_private', 'storage', 'auth')
order by 1, 2, 3;
