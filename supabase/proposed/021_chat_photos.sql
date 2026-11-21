-- Proposed only. Do not apply this on the live project from CI.
-- Orr applies it after review. No edge function and no paid add-on.
--
-- A chat photo is ciphertext in the private chat-photos bucket. The row
-- holds the same sealed envelopes as a text message, wrapping the content
-- key. The bucket holds the photo ciphertext, never a JPEG.
--
-- View once expires seven days after insert. The trigger sets that clock.
-- Removing the object bytes happens when a phone opens the chat, because
-- storage.protect_delete refuses a SQL delete. That sweep is free.
--
-- Either partner can delete a photo row. Text and notices stay sender-only.
-- There is still no update grant. consume_chat_photo and expire_chat_photos
-- are the only writes after insert.

create or replace function public.chat_photo_couple(p_name text)
returns uuid
language sql
immutable
as $$
  select case
    when split_part(p_name, '/', 1) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then split_part(p_name, '/', 1)::uuid
    else null
  end
$$;

insert into storage.buckets (id, name, public)
values ('chat-photos', 'chat-photos', false)
on conflict (id) do update set public = false;

do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'storage' and table_name = 'buckets' and column_name = 'file_size_limit'
  ) then
    update storage.buckets
    set file_size_limit = 10485888,
        allowed_mime_types = array['application/octet-stream']::text[]
    where id = 'chat-photos';
  end if;
end $$;

alter table storage.objects enable row level security;

drop policy if exists chat_photos_select on storage.objects;
drop policy if exists chat_photos_insert on storage.objects;
drop policy if exists chat_photos_delete on storage.objects;

create policy chat_photos_select on storage.objects
for select to authenticated
using (
  bucket_id = 'chat-photos'
  and public.is_couple_member(public.chat_photo_couple(name))
);

create policy chat_photos_insert on storage.objects
for insert to authenticated
with check (
  bucket_id = 'chat-photos'
  and public.is_couple_member(public.chat_photo_couple(name))
);

create policy chat_photos_delete on storage.objects
for delete to authenticated
using (
  bucket_id = 'chat-photos'
  and public.is_couple_member(public.chat_photo_couple(name))
);

alter table public.chat_messages
  add column if not exists kind text not null default 'text',
  add column if not exists retention text,
  add column if not exists photo_path text,
  add column if not exists opened_at timestamptz,
  add column if not exists expires_at timestamptz;

alter table public.chat_messages drop constraint if exists chat_messages_kind_check;
alter table public.chat_messages
  add constraint chat_messages_kind_check
  check (kind in ('text', 'photo', 'notice'));

alter table public.chat_messages drop constraint if exists chat_messages_photo_check;
alter table public.chat_messages
  add constraint chat_messages_photo_check
  check (
    (
      kind in ('text', 'notice')
      and retention is null
      and photo_path is null
      and opened_at is null
      and expires_at is null
    )
    or (
      kind = 'photo'
      and retention = 'keep'
      and opened_at is null
      and expires_at is null
      and photo_path = lower(couple_id::text) || '/' || lower(id::text) || '.bin'
    )
    or (
      kind = 'photo'
      and retention = 'view_once'
      and expires_at is not null
      and (
        photo_path = lower(couple_id::text) || '/' || lower(id::text) || '.bin'
        or photo_path is null
      )
    )
  );

create or replace function app_private.guard_chat_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  recent int;
  expected text;
begin
  if auth.uid() is null or new.sender_user_id is distinct from auth.uid() then
    raise exception 'not_authenticated';
  end if;
  if app_private.is_chat_public_key(new.sender_public_key) = false then
    raise exception 'bad_key';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(new.sender_user_id::text, 0));
  if not exists (
    select 1
    from public.device_keys
    where user_id = new.sender_user_id
      and public_key = new.sender_public_key
      and retired_at is null
  ) then
    raise exception 'unknown_sender_key';
  end if;
  if new.kind is null or new.kind = 'text' then
    new.kind := 'text';
    if new.retention is not null or new.photo_path is not null or new.opened_at is not null or new.expires_at is not null then
      raise exception 'bad_photo';
    end if;
  elsif new.kind = 'notice' then
    if new.retention is not null or new.photo_path is not null or new.opened_at is not null or new.expires_at is not null then
      raise exception 'bad_photo';
    end if;
  elsif new.kind = 'photo' then
    if new.retention not in ('view_once', 'keep') then
      raise exception 'bad_photo';
    end if;
    expected := lower(new.couple_id::text) || '/' || lower(new.id::text) || '.bin';
    if new.photo_path is distinct from expected then
      raise exception 'bad_photo_path';
    end if;
    new.opened_at := null;
    if new.retention = 'view_once' then
      new.expires_at := now() + interval '7 days';
    else
      new.expires_at := null;
    end if;
  else
    raise exception 'bad_photo';
  end if;
  select count(*) into recent
  from public.chat_messages
  where sender_user_id = new.sender_user_id
    and created_at > now() - interval '1 minute';
  if recent >= 30 then
    raise exception 'chat_rate';
  end if;
  new.created_at := now();
  return new;
end;
$$;

drop policy if exists chat_messages_delete on public.chat_messages;
create policy chat_messages_delete on public.chat_messages
for delete to authenticated
using (
  public.is_couple_member(couple_id)
  and (sender_user_id = auth.uid() or kind = 'photo')
);

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
  set opened_at = now(), photo_path = null
  where id = p_message_id;
end;
$$;

create or replace function public.expire_chat_photos()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  update public.chat_messages
  set photo_path = null
  where kind = 'photo'
    and retention = 'view_once'
    and opened_at is null
    and photo_path is not null
    and expires_at <= now()
    and public.is_couple_member(couple_id);
end;
$$;

revoke all on function public.chat_photo_couple(text) from public, anon;
revoke all on function public.consume_chat_photo(uuid) from public, anon, authenticated;
revoke all on function public.expire_chat_photos() from public, anon, authenticated;
grant execute on function public.chat_photo_couple(text) to authenticated;
grant execute on function public.consume_chat_photo(uuid) to authenticated;
grant execute on function public.expire_chat_photos() to authenticated;
