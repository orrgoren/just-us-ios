# Supabase Apple provider and APNs secrets

Nothing in this repository is applied to Supabase. Orr reviews this page, then the values are entered by hand. The private key stays in GitHub secrets and in Supabase secrets. It is not committed.

The same Apple key covers APNs and Sign in with Apple for `com.orrgoren.justus`.

| Fact | Value |
| --- | --- |
| Bundle ID / native client ID | `com.orrgoren.justus` |
| App ID resource | `XZ2BWSBK3R` |
| Team ID | `694YR89B4S` |
| Key ID | `S6M487B43U` |
| Private key | GitHub secret `APNS_KEY_P8` (also the Sign in with Apple key) |

## Apple provider

In the Supabase dashboard for project `vowmukhhnfhtnjlswkun`: Authentication → Sign In / Providers → Apple.

| Dashboard field | Value |
| --- | --- |
| Enable Sign in with Apple | On |
| Client IDs | `com.orrgoren.justus` |
| Team ID used to build the client secret | `694YR89B4S` |
| Key ID | `S6M487B43U` |
| Private key (.p8) | Contents of `APNS_KEY_P8` |

Client IDs is a comma-separated allow list. The native app sends an Apple identity token whose `aud` is the bundle ID, so the list is exactly `com.orrgoren.justus`. Do not add a Services ID unless a web Sign in with Apple flow is added later.

Supabase asks for an OAuth client secret (a short-lived JWT). Generate that secret from the team ID, key ID, and `.p8` above. Apple client secrets expire about every six months and have to be rotated with the same key until the key itself is revoked. Paste the generated secret into the provider. Do not paste it into this repository.

The app sends Sign in with Apple as an ID token, not as a web OAuth redirect:

1. Create a random raw nonce.
2. Set the Apple request nonce to the hex SHA-256 of that raw nonce.
3. Call `signInWithIdToken` with provider `apple`, the identity token, and the raw nonce.

Callback URL, if the dashboard shows one: `https://vowmukhhnfhtnjlswkun.supabase.co/auth/v1/callback`. The native ID-token path does not open it.

## Edge Function secrets

The proposed sender is `supabase/proposed/functions/send-push/index.ts`. Deploy it only after this page is approved. Set the function secrets to:

| Secret | Value |
| --- | --- |
| `APNS_KEY_ID` | `S6M487B43U` |
| `APNS_TEAM_ID` | `694YR89B4S` |
| `APNS_BUNDLE_ID` | `com.orrgoren.justus` |
| `APNS_KEY_P8` | Contents of GitHub secret `APNS_KEY_P8`, including the PEM header and footer |
| `APNS_USE_SANDBOX` | `true` only for a development-entitlement build. Internal TestFlight uses the production entitlement, so leave this unset or `false` for TestFlight. |

Example, run locally by a person who already has the `.p8`, not by CI:

```bash
supabase secrets set \
  APNS_KEY_ID=S6M487B43U \
  APNS_TEAM_ID=694YR89B4S \
  APNS_BUNDLE_ID=com.orrgoren.justus \
  APNS_KEY_P8="$(cat AuthKey_S6M487B43U.p8)" \
  --project-ref vowmukhhnfhtnjlswkun
```

The function also needs the service role to read `device_tokens`. Supabase injects `SUPABASE_SERVICE_ROLE_KEY` into Edge Functions. Do not copy that key into the iOS app or into GitHub Actions.

Push copy, quiet hours (22:00–08:00 local), the one-non-transactional-push-per-day cap, and the six-hour dedupe for mood and invite-accepted live in `JustUs/Domain/PushPolicy.swift` and must stay identical in the function. The reveal payload is the fixed sentence “Your date is ready to reveal.” It never includes the place, the outfit, or the idea title.

## Related schema

`supabase/proposed/001_push_devices_and_account.sql` adds device tokens, notification preferences, the photo column, account deletion, and unlink. It is not applied. The iOS client calls `delete_my_account` and `leave_couple` and, until those functions exist, shows that nothing changed.

## What GitHub Actions already has

These secrets are set on `orrgoren/just-us-ios` and are not printed by the workflows:

- `SUPABASE_URL`, `SUPABASE_ANON_KEY`
- `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`
- `APPLE_TEAM_ID` (`694YR89B4S`)
- `APNS_KEY_ID` (`S6M487B43U`), `APNS_KEY_P8`

The TestFlight workflow signs with the App Store Connect API key and `APPLE_TEAM_ID`. It does not upload the APNs key. The APNs key is only for the Edge Function above.
