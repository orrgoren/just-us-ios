-- Applied live as migration device_tokens_authenticated_grant. Do not re-apply.
-- device_tokens_own was already in place. authenticated had no table grant,
-- so every upsert failed with permission denied and the table stayed empty.
grant select, insert, update, delete on public.device_tokens to authenticated;
