-- Needs applying on live. 021 is already applied; this replaces consume_chat_photo
-- and adds the notice dedupe. Do not edit 021.
--
-- Opening a view-once photo stamps opened_at immediately and leaves photo_path
-- in place until the storage object is actually gone. A second phone, or a
-- reinstall, then sees it as opened even while the delete is still retrying.
-- clear_chat_photo_path drops the path after that delete succeeds.
--
-- One screenshot notice per photo per sender. A second insert of the same
-- pair is a unique violation, which the client treats as "already noted".
-- device_keys joins supabase_realtime so a retired or new key drops the
-- cached key ring. The publication add is skipped when the table is already in it.

alter table public.chat_messages
  add column if not exists notice_message_id uuid;

create unique index if not exists chat_messages_one_notice
  on public.chat_messages (sender_user_id, notice_message_id)
  where kind = 'notice' and notice_message_id is not null;

create or replace function public.consume_chat_photo(p_message_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.chat_messages;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  select * into v_row from public.chat_messages where id = p_message_id;
  if v_row.id is null or public.is_couple_member(v_row.couple_id) = false then
    raise exception 'not_found';
  end if;
  if v_row.kind is distinct from 'photo' or v_row.retention is distinct from 'view_once' then
    raise exception 'not_view_once';
  end if;
  if v_row.opened_at is not null or v_row.photo_path is null then
    return;
  end if;
  if v_row.sender_user_id = auth.uid() then
    raise exception 'sender_cannot_consume';
  end if;
  if v_row.expires_at <= now() then
    raise exception 'expired';
  end if;
  update public.chat_messages
  set opened_at = now()
  where id = p_message_id;
end;
$$;

create or replace function public.clear_chat_photo_path(p_message_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.chat_messages;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  select * into v_row from public.chat_messages where id = p_message_id;
  if v_row.id is null or public.is_couple_member(v_row.couple_id) = false then
    raise exception 'not_found';
  end if;
  if v_row.opened_at is null then
    raise exception 'not_opened';
  end if;
  update public.chat_messages
  set photo_path = null
  where id = p_message_id;
end;
$$;

revoke all on function public.clear_chat_photo_path(uuid) from public, anon, authenticated;
grant execute on function public.clear_chat_photo_path(uuid) to authenticated;

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
      and relation.relname = 'device_keys'
  ) then
    alter publication supabase_realtime add table public.device_keys;
  end if;
end $$;
