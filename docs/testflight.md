# TestFlight

Two upload paths exist. Use one at a time.

GitHub Actions runs `.github/workflows/testflight.yml` after the pull request is green and QA has signed off. The input `confirm` must be the word `upload`. Any other value exits before the archive. The lane is fastlane `ios beta`. It checks that Sign in with Apple is present on the Release entitlements, the App Store profile, and the exported app, and it sets the build number one above the latest TestFlight build.

Xcode Cloud is the other path. The steps, the two required secrets, and the workflow Orr creates are in [xcode-cloud.md](xcode-cloud.md).

| Check | Expected |
| --- | --- |
| Bundle ID | `com.orrgoren.justus` |
| Capabilities | Push Notifications and Sign in with Apple |

The generated project uses automatic signing. Xcode Cloud does not use a manual profile. Associated Domains is not in the entitlements yet. The App ID does not include that capability, and an entitlement without it would fail signing. Invite links still parse when the app is opened with `justus://` or an `https` invite URL.
