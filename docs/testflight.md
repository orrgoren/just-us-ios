# TestFlight

Uploads run in Xcode Cloud. The steps, the two required secrets, and the workflow Orr creates are in [xcode-cloud.md](xcode-cloud.md).

The GitHub workflow `.github/workflows/testflight.yml` is only a bookmark. Dispatching it does not archive and does not sign.

| Check | Expected |
| --- | --- |
| Bundle ID | `com.orrgoren.justus` |
| Capabilities | Push Notifications and Sign in with Apple |

The generated project uses automatic signing. Xcode Cloud does not use a manual profile. Associated Domains is not in the entitlements yet. The App ID does not include that capability, and an entitlement without it would fail signing. Invite links still parse when the app is opened with `justus://` or an `https` invite URL.
