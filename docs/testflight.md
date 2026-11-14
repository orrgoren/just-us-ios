# TestFlight

The upload is manual. CI does not run it, and this change does not dispatch it.

Run the **TestFlight** workflow only after the pull request is green and QA has signed off. The workflow input `confirm` must be the word `upload`. Any other value exits without archiving.

The lane checks the existing App ID. It does not register a bundle id.

| Check | Expected |
| --- | --- |
| Bundle ID | `com.orrgoren.justus` |
| Resource id | `XZ2BWSBK3R` |
| Capabilities | `PUSH_NOTIFICATIONS`, `APPLE_ID_AUTH` |

Signing uses the App Store Connect API key (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`) and `APPLE_TEAM_ID` (`694YR89B4S`). No certificates are committed. If the App Store Connect app record “Just Us” (English, sku `just-us-ios`) is missing, the lane creates that record only. It does not modify the App ID.

`APNS_KEY_ID` (`S6M487B43U`) and `APNS_KEY_P8` are not used by the upload. They belong to the Supabase Edge Function in [supabase-apple-and-apns.md](supabase-apple-and-apns.md).

Associated Domains is not in the entitlements yet. The registered App ID does not include that capability, and an entitlement without it would fail signing. Invite links still parse when the app is opened with `justus://` or an `https` invite URL.
