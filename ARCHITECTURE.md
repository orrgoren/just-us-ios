# Architecture

Just Us is a SwiftUI app for iOS 17. English is the development language. User-facing copy lives in `L10n` and `Localizable.xcstrings`. Views use leading and trailing edges.

The domain (`Schedule`, `Recommendation`, `PushPolicy`, `RitualPrivacy`) mirrors the web rules: Thursday math in `Asia/Jerusalem`, three home nights then one out, planner index, and a sealed plan for the partner. Idea titles on iOS come from the bundled English catalog, keyed by the same ids as the web.

`DateBackend` has two implementations. `-uitest` and screenshots use `FakeBackend`. A normal launch uses `LiveBackend` and supabase-swift 2.55.6. The live client calls the existing RPCs (`create_couple`, `redeem_couple_invite`, `complete_date`, `ensure_active_draft`, `leave_couple`) and reads the same tables as the web. `leave_couple` is live. The replacement in `supabase/proposed/003_memory_photo_and_close.sql` was applied on 2026-11-15. Do not re-apply it. It closes the whole couple when either person unlinks, keeps both logins, tells the other person on their next launch, and returns the couple id it closed. `004_delete_my_account.sql` was applied on 2026-11-15. Do not re-apply it. Deleting an account closes every couple the person still touches, including one they already left, and removes their login. The other person's login stays. Photos for a leave are removed afterward by the deployed `delete-couple-photos` function, only for those closed ids, and only through the Storage API. A failed call still finishes the leave on the phone. Account deletion does not call the function, because that login is already gone. The next launch retries a leave, and `justus-photo-sweep` retries rows whose login is already gone. SQL does not delete `storage.objects`. The iOS app calls `send-push` after a mood, a saved plan, and a redeemed invite. Weekly reminders and invite nudges are not sent by the client.

Push registration writes `device_tokens`. The replacement sender is `supabase/proposed/functions/send-push` and is not deployed. Secret names are in `docs/supabase-apple-and-apns.md`. The values are not in this repository.

Sign in with Apple hashes the nonce for the Apple request and sends the raw nonce to Supabase. In UI tests the system sheet is skipped.

Analytics and crash reports go to `os.Logger`. There is no third-party SDK.
