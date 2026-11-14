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

## Apple and push

The App ID `com.orrgoren.justus` (`XZ2BWSBK3R`) already has Push Notifications and Sign in with Apple. Fastlane only verifies that. TestFlight is a manual workflow and is not dispatched here. See `docs/testflight.md`.

Supabase still needs the Apple provider and the APNs Edge Function secrets. Do not apply them until Orr approves. The values are:

| Setting | Value |
| --- | --- |
| Client IDs | `com.orrgoren.justus` |
| Team ID | `694YR89B4S` |
| Key ID | `S6M487B43U` |
| Private key | GitHub secret `APNS_KEY_P8` (same key for APNs and Sign in with Apple) |

Edge Function secrets: `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_KEY_P8`, and `APNS_USE_SANDBOX` when the build uses the development push entitlement. The full field list is in [docs/supabase-apple-and-apns.md](docs/supabase-apple-and-apns.md).

`supabase/proposed/001_push_devices_and_account.sql` is already live (device tokens, notification preferences, author name, the photo column, the date-photos bucket, and `leave_couple`). Do not apply it again. `002_push_deliveries.sql`, `003_memory_photo_and_leave_handoff.sql`, `004_delete_my_account.sql`, and the rewritten `send-push` are not applied. The deployed sender is still v1.
