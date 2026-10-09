# Pubky auth

This suite covers the uniquely targetable `bitkit://pubky-auth/setup` OS handoff into Bitkit. The wrapper carries the Paykit grant-auth requester fields, normalizes to `pubkyauth://signin_grant`, and is the only Pubky request accepted from an OS link. `lightning:`/`lnurl*:`-prefixed raw Pubky auth and signup requests are rejected before authorization.
It stops at explicit watch-only consent and never authorizes or exports account material.
Bitkit retains links delivered during startup, restoration, or PIN entry and presents consent only after the main wallet UI is available.

## Preconditions

- Build and run Bitkit with `E2E_BUILD`.
- Complete wallet onboarding.
- Create a Pubky profile in Bitkit so the wallet has a local identity secret.

The journey uses a syntactically valid dummy request and does not contact its relay unless the authorization flow is completed.

## Grant signup

- `grant-signup.xml` checks consent, cancellation, homeserver registration, and profile setup for a fresh identity.
- `grant-signup-existing-identity.xml` checks approval with an existing identity without opening profile setup.

Both require a fresh `pubkyauth://signup_grant` URL from a controlled requesting app, a reachable
homeserver and authorization relay, and a valid invite when required. The new-identity fixture
uses ordinary app permissions without a Bitkit companion claim.

Deliver each grant signup request through the main wallet scanner: copy the complete URL to the
device clipboard, tap **Scan**, then **Paste**, and allow clipboard access if prompted. Camera
permission is not required for Paste. Use this route on both platforms; iOS does not register the
raw `pubkyauth` scheme for OS link delivery.
