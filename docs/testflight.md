# TestFlight

The upload is manual. CI does not run it, and this change does not dispatch it.

Run the **TestFlight** workflow only after the pull request is green and QA has signed off. The workflow input `confirm` must be the word `upload`. Any other value exits without archiving.

The lane checks the existing App ID. It does not register a bundle id.

| Check | Expected |
| --- | --- |
| Bundle ID | `com.orrgoren.justus` |
| Resource id | `XZ2BWSBK3R` |
| Capabilities | `PUSH_NOTIFICATIONS`, `APPLE_ID_AUTH` |

Signing uses the App Store Connect API key (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`) and `APPLE_TEAM_ID` (`694YR89B4S`). Each upload revokes every Apple Distribution and iOS Distribution certificate on that team, because the runner keychain is empty and those private keys are already gone. It then creates one new Apple Distribution certificate in the runner keychain and recreates the App Store profile `Just Us App Store` for that certificate. The archive uses manual signing on the JustUs app target only (`CODE_SIGN_IDENTITY` `Apple Distribution`, export method `app-store`, profile `Just Us App Store`). Those settings are not passed as global xcodebuild arguments, so Swift package targets are not given a provisioning profile. Revoking a distribution certificate does not remove a build Apple has already accepted for TestFlight or the App Store. The lane does not request a Development profile and does not register a device. No certificates, profiles, or keys are committed. The App Store Connect record is “Just Us Couples” (English, sku `just-us-ios`). The lane finds it by bundle id and does not rename it. If that record is missing, the lane creates it with that name. It does not modify the App ID.

`APNS_KEY_ID` (`S6M487B43U`) and `APNS_KEY_P8` are not used by the upload. They belong to the Supabase Edge Function in [supabase-apple-and-apns.md](supabase-apple-and-apns.md).

Associated Domains is not in the entitlements yet. The registered App ID does not include that capability, and an entitlement without it would fail signing. Invite links still parse when the app is opened with `justus://` or an `https` invite URL.
