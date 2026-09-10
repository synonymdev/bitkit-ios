# Pubky auth

This suite covers the uniquely targetable `bitkit://pubky-auth/setup` OS handoff into Bitkit. The wrapper carries the Paykit grant-auth requester fields, normalizes to `pubkyauth://signin_grant`, and is the only Pubky request accepted from an OS link. `lightning:`/`lnurl*:`-prefixed raw Pubky auth and signup requests are rejected before authorization.
It stops at explicit watch-only consent and never authorizes or exports account material.
Bitkit retains links delivered during startup, restoration, or PIN entry and presents consent only after the main wallet UI is available.

## Preconditions

- Build and run Bitkit with `E2E_BUILD`.
- Complete wallet onboarding.
- Enable Paykit UI in developer settings.
- Create a Pubky profile in Bitkit so the wallet has a local identity secret.

The journey uses a syntactically valid dummy request and does not contact its relay unless the authorization flow is completed.
