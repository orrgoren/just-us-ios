# Architecture

Just Us is a SwiftUI app for iOS 17. English is the development language. User-facing copy lives in `L10n` and `Localizable.xcstrings`. Views use leading and trailing edges.

The domain (`Schedule`, `Recommendation`, `PushPolicy`, `RitualPrivacy`) mirrors the web rules: Thursday math in `Asia/Jerusalem`, three home nights then one out, planner index, and a sealed plan for the partner. Idea titles on iOS come from the bundled English catalog, keyed by the same ids as the web.

`DateBackend` has two implementations. `-uitest` and screenshots use `FakeBackend`. A normal launch uses `LiveBackend` and supabase-swift 2.55.6. The live client calls the existing RPCs (`create_couple`, `redeem_couple_invite`, `complete_date`, `ensure_active_draft`) and reads the same tables as the web. `delete_my_account` and `leave_couple` are proposed in `supabase/proposed` and are not applied. Until they exist, the app says nothing changed.

Push registration is stored only if `device_tokens` exists. The Edge Function that would send APNs is proposed and not deployed. The exact Apple provider fields and function secrets are in `docs/supabase-apple-and-apns.md`.

Sign in with Apple hashes the nonce for the Apple request and sends the raw nonce to Supabase. In UI tests the system sheet is skipped.

Analytics and crash reports go to `os.Logger`. There is no third-party SDK.
