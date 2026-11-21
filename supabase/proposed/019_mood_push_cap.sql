-- Proposed only. Do not apply this on the live project from CI.
-- Orr applies it after review, then redeploys send-push.
--
-- A mood alert skips the daily non-transactional cap, the same way a chat
-- message does. A mood still waits six hours before another mood alert.
-- Chat keeps its 60 second coalesce and does not use the six hour window.
-- The body is claim_push_delivery from 018, with that one change.

create or replace function public.claim_push_delivery(
  p_recipient uuid,
  p_kind text,
  p_timezone text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_today date;
  v_transactional boolean := p_kind in ('chatMessage', 'partnerMood');
begin
  if p_kind not in ('partnerMood', 'planReady', 'inviteAccepted', 'weeklyReminder', 'inviteNudge', 'chatMessage') then
    raise exception 'kind';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_recipient::text, 0));
  begin
    v_today := (now() at time zone p_timezone)::date;
  exception
    when others then
      raise exception 'invalid_timezone';
  end;
  if p_kind = 'chatMessage' and exists (
    select 1
    from public.push_deliveries
    where recipient_user_id = p_recipient
      and kind = 'chatMessage'
      and sent_at > now() - interval '60 seconds'
  ) then
    raise exception 'coalesced';
  end if;
  if p_kind = 'partnerMood' and exists (
    select 1
    from public.push_deliveries
    where recipient_user_id = p_recipient
      and kind = 'partnerMood'
      and sent_at > now() - interval '6 hours'
  ) then
    raise exception 'deduped_6h';
  end if;
  if v_transactional = false and exists (
    select 1 from public.push_deliveries
    where recipient_user_id = p_recipient
      and kind = p_kind
      and sent_at > now() - interval '6 hours'
  ) then
    raise exception 'deduped_6h';
  end if;
  if v_transactional = false and exists (
    select 1 from public.push_deliveries
    where recipient_user_id = p_recipient
      and transactional = false
      and (sent_at at time zone p_timezone)::date = v_today
  ) then
    raise exception 'daily_non_transactional';
  end if;
  insert into public.push_deliveries (recipient_user_id, kind, transactional)
  values (p_recipient, p_kind, v_transactional)
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.claim_push_delivery(uuid, text, text) from public, anon, authenticated;
grant execute on function public.claim_push_delivery(uuid, text, text) to service_role;
