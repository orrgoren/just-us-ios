# Xcode Cloud

Xcode Cloud is one of two TestFlight upload paths. The other is GitHub Actions: `.github/workflows/testflight.yml` runs the fastlane `ios beta` lane on `workflow_dispatch` when `confirm` is `upload`. That lane checks the Sign in with Apple entitlement and sets the build number one above the latest TestFlight build. Use one path at a time.

This path archives with automatic signing. `project.yml` already sets `CODE_SIGN_STYLE` to Automatic. Leave the provisioning profile unset in the Xcode Cloud workflow.

The post-clone script is `ci_scripts/ci_post_clone.sh`. It installs xcodegen, generates `JustUs.xcodeproj`, writes `Config/Secrets.xcconfig`, and sets `CURRENT_PROJECT_VERSION` to `CI_BUILD_NUMBER + 2`. Xcode Cloud’s counter starts at 1, and TestFlight already has build 2, so the first archive is build 3.

## Secrets Orr adds on the workflow

In App Store Connect, open the workflow, then Environment. Add these as secret environment variables. The script reads them by name and does not print the key.

| Variable | Required |
| --- | --- |
| `SUPABASE_URL` | Yes. The project URL, including `https://`. |
| `SUPABASE_ANON_KEY` | Yes. The anon key. |

Do not add `APNS_KEY_P8`, `APNS_KEY_ID`, `ASC_KEY_P8`, or `APPLE_TEAM_ID`. The archive does not use them. Xcode Cloud signs with the App Store Connect connection for this Apple team.

## Workflow to create

1. App Store Connect → Apps → Just Us Couples → Xcode Cloud (or Xcode → Product → Xcode Cloud → Create Workflow, same app).
2. Product: the `orrgoren/just-us-ios` repository. Grant Xcode Cloud access to that repo. After the repo is private, the grant still has to include the private repository.
3. Name the workflow `Just Us TestFlight`.
4. Environment: latest macOS and latest Xcode. Add the two secrets above.
5. Start condition: **Manual** for the first archive. After that archive is in TestFlight, edit the start condition to **Branch Changes** on `main` if every merge should upload. A manual start is Start Build in App Store Connect or Product → Xcode Cloud → Start Build in Xcode.
6. Actions: **Archive**. Platform iOS. Scheme `JustUs`. Signing automatic. No custom provisioning profile.
7. Post-actions: **TestFlight Internal Testing**. Group `Goren`. If that group does not exist, create it under TestFlight → Internal Testing → Groups, name it `Goren`, and add Orr. Internal groups do not need a beta review.
8. Save, then start the first build by hand. The build has to finish `ci_post_clone.sh` before it can see `JustUs.xcodeproj`, because that project is generated and is not committed.

## GitHub Actions

`.github/workflows/testflight.yml` stays beside this workflow. Dispatch it with `confirm` set to `upload` when Xcode Cloud is idle for this app. The lane checks Sign in with Apple and numbers the build one above the latest TestFlight build.

`ci.yml` stays. On a private repository the macOS minutes are the expensive ones. When that starts to matter, keep the Linux jobs (the account SQL check and the file filter) and move `JustUsTests` to a second Xcode Cloud workflow whose only action is Test, scheme `JustUs`, without a TestFlight post-action. Leave the UI tests on a manual dispatch.
