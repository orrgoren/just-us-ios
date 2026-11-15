# Supabase Apple provider and APNs secrets

The values are entered in the Supabase dashboard and stored as secrets. They are not written in this repository. The private key is not committed. The SQL in this repository is not a migration.

The same Apple key covers APNs and Sign in with Apple for `com.orrgoren.justus`.

## Apple provider

In the Supabase dashboard: Authentication → Sign In / Providers → Apple.

| Dashboard field | What to enter |
| --- | --- |
| Enable Sign in with Apple | On |
| Client IDs | `com.orrgoren.justus` |
| Team ID | The Apple team, from the developer account. Not copied here. |
| Key ID | The key id for that team’s Sign in with Apple key. Not copied here. |
| Private key (.p8) | The contents of that key, including the PEM header and footer. |

Client IDs is a comma-separated allow list. The native app sends an Apple identity token whose `aud` is the bundle ID, so the list is exactly `com.orrgoren.justus`. Do not add a Services ID unless a web Sign in with Apple flow is added later.

Supabase asks for an OAuth client secret (a short-lived JWT). Generate that secret from the team ID, key ID, and `.p8`. Apple client secrets expire about every six months and have to be rotated with the same key until the key itself is revoked. Paste the generated secret into the provider. Do not paste it into this repository.

The app sends Sign in with Apple as an ID token, not as a web OAuth redirect:

1. Create a random raw nonce.
2. Set the Apple request nonce to the hex SHA-256 of that raw nonce.
3. Call `signInWithIdToken` with provider `apple`, the identity token, and the raw nonce.

## Edge Function secrets

Live `send-push` is v3, deployed from `main` at `a12f1d1` with `verify_jwt` on. That deployed source is `supabase/proposed/functions/send-push/index.ts`. `002_push_deliveries.sql`, `006_push_claim_and_outbox.sql`, and `007_push_flush_schedule.sql` are already live, in that order. Do not re-apply them. The flush cron sends the legacy service_role JWT from the vault. The function env may hold the newer `sb_secret` key, so the live sender accepts that flush by the JWT `role` claim. A queued push is removed on a final decision and kept only for a retryable APNs failure, up to the attempt cap. The APNs provider token is reused for 50 minutes. `verify_jwt` is pinned on in `supabase/config.toml`. Set the function secrets to:

| Secret | What to enter |
| --- | --- |
| `APNS_KEY_ID` | The Apple key id. Not copied here. |
| `APNS_TEAM_ID` | The Apple team id. Not copied here. |
| `APNS_BUNDLE_ID` | `com.orrgoren.justus` |
| `APNS_KEY_P8` | The `.p8` contents, including the PEM header and footer. |
| `APNS_USE_SANDBOX` | `true` only for a development-entitlement build. Leave it unset or `false` for TestFlight. |

A person who already has the `.p8` sets those secrets from their own machine. CI does not. The function also needs the service role to read `device_tokens`. Supabase injects `SUPABASE_SERVICE_ROLE_KEY` into Edge Functions. Do not copy that key into the iOS app or into GitHub Actions.

Copy for a notification is chosen in `JustUs/Domain/PushPolicy.swift` and in the live `send-push` function. The two have to match. The message does not include the place, the outfit, or the idea title.

## Related schema

Already live: `device_tokens`, `notification_preferences`, `memory_notes.author_name`, `dates.memory_photo_path`, the private `date-photos` bucket, `mood_votes` in `supabase_realtime`, and `leave_couple()` for `authenticated` only. `supabase/proposed/001_push_devices_and_account.sql` records that proposal. Do not apply it again.

Applied live on 2026-11-15. Do not re-apply. The push migrations went on in this order: 002, then 006, then 007.

- `supabase/proposed/002_push_deliveries.sql` — applied at `20261115092359`. The push send log is live.
- `supabase/proposed/006_push_claim_and_outbox.sql` — applied at `20261115092405`. `device_tokens.environment` is live, with columns `user_id`, `token`, `platform`, `updated_at`, and `environment`.
- `supabase/proposed/007_push_flush_schedule.sql` — applied after 006. The push flush schedule is live.
- `supabase/proposed/003_memory_photo_and_close.sql` — photo path on a completed date. Unlink closes the whole couple for both people and returns that couple id. pg_cron, pg_net, and `justus-photo-sweep` are on.
- `supabase/proposed/004_delete_my_account.sql` — account deletion. Either partner closes every couple they still touch. The other person stays unpaired.
- `supabase/proposed/functions/delete-couple-photos/index.ts` — live as v3, deployed from `main` at `a12f1d1` with `verify_jwt` on. The app calls it after unlink. Account deletion leaves the rows for the sweep, because that login is already gone. The sweep bearer is the legacy service_role JWT in the vault. The function env may hold the newer `sb_secret` key, so the sweep is recognized by the JWT `role` claim after the gateway has checked the signature.

Not applied, and must never be applied:

- `supabase/proposed/005_rollback.sql` and `supabase/proposed/live/` — one transaction, with the live function bodies inlined. It unschedules `justus-push-flush`. Not applied. Do not apply it.

The TestFlight build calls `leave_couple` and then `delete-couple-photos`. It does not call the function after `delete_my_account`. The function deletes photos only for couple ids the leave closed, and only when `photo_delete_allowed` says that couple row is already gone. A failed call leaves the id in `closed_couples`. `justus-photo-sweep` posts `{"sweep":true}` with the `justus_service_role` vault secret. The sweep is what clears photos after account deletion. The next launch also retries for the person who left. `005_rollback.sql` would restore the previous `leave_couple` and unschedule the sweep. It is not applied and must never be applied. Do not apply `003` or `004` again. `scripts/sql/live-fk-dump.sql` is read-only and lists live foreign keys and delete triggers.

## What GitHub Actions already has

These secrets are set on the repository and are not printed by the workflows:

- `SUPABASE_URL`, `SUPABASE_ANON_KEY`
- `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`
- `APPLE_TEAM_ID`
- `APNS_KEY_ID`, `APNS_KEY_P8`

Xcode Cloud does not use the Apple or APNs secrets. It only needs `SUPABASE_URL` and `SUPABASE_ANON_KEY`. See [xcode-cloud.md](xcode-cloud.md).
