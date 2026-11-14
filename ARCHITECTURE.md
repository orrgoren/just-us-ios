# Architecture

Just Us is a SwiftUI app for iOS 17. English is the development language. User-facing copy lives in `L10n` and `Localizable.xcstrings`. Views use leading and trailing edges.

The domain (`Schedule`, `Recommendation`, `PushPolicy`, `RitualPrivacy`) mirrors the web rules: Thursday math in `Asia/Jerusalem`, three home nights then one out, planner index, and a sealed plan for the partner. Idea titles on iOS come from the bundled English catalog, keyed by the same ids as the web.

`DateBackend` has two implementations. `-uitest` and screenshots use `FakeBackend`. A normal launch uses `LiveBackend` and supabase-swift 2.55.6. The live client calls the existing RPCs (`create_couple`, `redeem_couple_invite`, `complete_date`, `ensure_active_draft`, `leave_couple`) and reads the same tables as the web. `leave_couple` is live, but the replacement that cancels an unrevealed night, moves `created_by`, and locks the couple row is in `supabase/proposed/003_memory_photo_and_leave_handoff.sql` and is not applied. `delete_my_account` is not live. Until `004_delete_my_account.sql` is applied, deleting an account says nothing changed. That proposal closes the whole couple for either partner and leaves the other person unpaired. The iOS app calls `send-push` after a mood, a saved plan, and a redeemed invite. Weekly reminders and invite nudges are not sent by the client.

Push registration writes `device_tokens`. The replacement sender is `supabase/proposed/functions/send-push` and is not deployed. Secret names are in `docs/supabase-apple-and-apns.md`. The values are not in this repository.

Sign in with Apple hashes the nonce for the Apple request and sends the raw nonce to Supabase. In UI tests the system sheet is skipped.

Analytics and crash reports go to `os.Logger`. There is no third-party SDK.
