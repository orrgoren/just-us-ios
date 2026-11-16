# QA

UI tests launch with `-uitest`, which resets an in-memory-backed fake and never calls Supabase. `-uitestKeep` keeps that fake across a relaunch. Screenshot launches use `-JustUsScreen` and `-JustUsAppearance` and also stay on the fake.

Live tests run only when `JUSTUS_ALLOW_LIVE_TESTS=1`, and they fail if the host is the production project `vowmukhhnfhtnjlswkun`.

The fake seeds two couples (Alex/Blair and Casey/Drew), Jordan’s open invite, Sam’s empty solo space, Riley’s kept solo history, and `demo@justus.app` (code `424242`, or `000000`). OTP `000000` succeeds, `111111` is expired, `222222` is wrong.

| Flow | Where it is covered |
| --- | --- |
| Bad email, wrong code, expired code, resend cooldown | `FlowUITests`, `FakeFlowTests` |
| Create a couple and show the invite | `FlowUITests` |
| Invalid, self, full, used, empty-solo replace | `FakeFlowTests` and the invite UI test |
| Partner cannot see the plan title | `FakeFlowTests` and the Blair UI test |
| Moods do not overwrite each other | `FakeFlowTests` |
| Partner mood deep link | `FlowUITests` |
| Sign out | `FlowUITests` |
| Delete requires the word `delete` | `FlowUITests` |
| Account deletion closes the shared space | `FakeFlowTests`, `AccountUITests` |
| Unlink closes the shared space | `FakeFlowTests` |
| Closed notice stays after the row is consumed | `FakeFlowTests`, `AccountUITests` |
| Offline write is not reported as saved | `FakeFlowTests` |
| Push, foreground | `PushUITests` via `simctl push` and `Fixtures/apns/plan-ready.apns` |
| Dynamic Type, light/dark, RTL, accessibility audit | `ScreenshotUITests`, `FlowUITests` |
| Daily cap, six-hour dedupe, invite windows, contrast | `DomainTests` |

Screenshots are test attachments named `se-` or `promax-` plus the screen, appearance, and text size. They are not committed.
