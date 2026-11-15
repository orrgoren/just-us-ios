# Just Us

A native SwiftUI app for one weekly date night. It uses the same Supabase project as the web app. This repository does not change that project.

English is the shipping language. The anon key is not committed. CI writes `Config/Secrets.xcconfig` from `SUPABASE_URL` and `SUPABASE_ANON_KEY`.

```bash
brew install xcodegen swiftlint
python3 scripts/write-secrets.py
xcodegen generate
open JustUs.xcodeproj
```

UI tests pass `-uitest` and stay on a fake. They do not call production. See `docs/qa.md`.

## Trigger a TestFlight build

Two upload paths exist. Use one at a time, so a second archive is not given the same build number.

GitHub Actions runs the fastlane `ios beta` lane from `.github/workflows/testflight.yml`. It is `workflow_dispatch` only. Set `confirm` to `upload`. Any other value exits before the archive. The lane checks that Sign in with Apple is in the Release entitlements, the App Store profile, and the exported app. The build number is one higher than the latest TestFlight build, which puts it above a build Xcode Cloud already uploaded.

Xcode Cloud archives the `JustUs` scheme and sends it to the internal TestFlight group `Goren`. The setup is in [docs/xcode-cloud.md](docs/xcode-cloud.md).

After that workflow exists:

1. App Store Connect → Apps → Just Us Couples → Xcode Cloud → the workflow `Just Us TestFlight`.
2. Start Build. The first run is manual. A later edit can start on every push to `main`.
3. The post-clone script generates the project and reads `SUPABASE_URL` and `SUPABASE_ANON_KEY` from the workflow secrets. Those are the only two secrets that archive needs.

Xcode Cloud signing is automatic. It uses no manual profile.

`ci.yml` still runs on GitHub. Private-repository macOS minutes are the tight ones. When that matters, keep the Linux jobs and run `JustUsTests` as an Xcode Cloud Test action instead. That trim is not done yet.

## Apple and push

The bundle id is `com.orrgoren.justus`. Supabase secret names, and the rule that the values stay out of this repository, are in [docs/supabase-apple-and-apns.md](docs/supabase-apple-and-apns.md).

`supabase/proposed/001_push_devices_and_account.sql` is already live (device tokens, notification preferences, author name, the photo column, the date-photos bucket, and `leave_couple`). Do not apply it again. `003_memory_photo_and_close.sql` and `004_delete_my_account.sql` were applied on 2026-11-15. Do not re-apply them. Live `delete-couple-photos` is v3, deployed from `main` at `a12f1d1` with `verify_jwt` on. `memory_notes.author_user_id` is still NOT NULL live. 001 and 004 do not drop that. `scripts/sql/live-fk-dump.sql` is the read-only query for live foreign keys and delete triggers. `002_push_deliveries.sql`, `006_push_claim_and_outbox.sql` (including `device_tokens.environment`), and `007_push_flush_schedule.sql` are live, in that order. Do not re-apply them. `009_redeem_invite_search_path.sql` is live as migration `redeem_invite_search_path`. It sets `redeem_couple_invite(text, boolean)` `search_path` to `public, extensions` so `digest()` resolves. Do not re-apply it. `005` and the live snapshots in `supabase/proposed/live/` are not applied. Do not apply `005`. `008_push_rollback.sql` is the push-only rollback. `012_scheduled_hint_notes.sql` is proposed and not applied. It lets the planner update `private_notes` on a scheduled, unrevealed date and freezes `idea_id` and `prepared_at` once the date leaves draft. Do not apply it until it is approved. Live `send-push` is v3, deployed from `main` at `a12f1d1` with `verify_jwt` on.
