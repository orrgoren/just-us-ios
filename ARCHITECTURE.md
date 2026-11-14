# Architecture

Just Us is a SwiftUI app for iOS 17. English is the development language. User-facing copy lives in `L10n` and `Localizable.xcstrings`. Views use leading and trailing edges.

The domain (`Schedule`, `Recommendation`, `PushPolicy`, `RitualPrivacy`) mirrors the web rules: Thursday math in `Asia/Jerusalem`, three home nights then one out, planner index, and a sealed plan for the partner. Idea titles on iOS come from the bundled English catalog, keyed by the same ids as the web.

`DateBackend` has two implementations. `-uitest` and screenshots use `FakeBackend`. A normal launch uses `LiveBackend` and supabase-swift 2.55.6. The live client calls the existing RPCs (`create_couple`, `redeem_couple_invite`, `complete_date`, `ensure_active_draft`, `leave_couple`) and reads the same tables as the web. `leave_couple` is live, but the replacement that cancels an unrevealed night, moves `created_by`, and locks the couple row is in `supabase/proposed/003_memory_photo_and_leave_handoff.sql` and is not applied. `delete_my_account` is not live. Until `004_delete_my_account.sql` is applied, deleting an account says nothing changed. The iOS app calls `send-push` after a mood, a saved plan, and a redeemed invite. Weekly reminders and invite nudges wait on the proposed outbox flush, which is not scheduled.

Push registration writes `device_tokens`. `send-push` v1 is deployed with `verify_jwt` on. The copy in `supabase/proposed/functions/send-push` is the replacement and is not deployed. The Apple provider fields and function secrets are in `docs/supabase-apple-and-apns.md`.

Sign in with Apple hashes the nonce for the Apple request and sends the raw nonce to Supabase. In UI tests the system sheet is skipped.

Analytics and crash reports go to `os.Logger`. There is no third-party SDK.
