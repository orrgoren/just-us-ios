-- Applied live as migration notification_preferences_authenticated_grant. Do not re-apply.
-- notification_preferences_own was already in place. authenticated had no
-- table grant, so preference toggles never wrote a row.
grant select, insert, update on public.notification_preferences to authenticated;
