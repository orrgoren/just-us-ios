-- Applied live on 2026-11-16 as migration chat_messages_realtime. Do not re-apply.
-- 015_partner_chat.sql created chat_messages without adding it to
-- supabase_realtime. The live statement is:
--   alter publication supabase_realtime add table public.chat_messages
-- The block below guards that statement so a second run does nothing.

do $$
begin
  if not exists (
    select 1
    from pg_publication_rel as publication_table
    join pg_publication as publication on publication.oid = publication_table.prpubid
    join pg_class as relation on relation.oid = publication_table.prrelid
    join pg_namespace as namespace on namespace.oid = relation.relnamespace
    where publication.pubname = 'supabase_realtime'
      and namespace.nspname = 'public'
      and relation.relname = 'chat_messages'
  ) then
    alter publication supabase_realtime add table public.chat_messages;
  end if;
end $$;
