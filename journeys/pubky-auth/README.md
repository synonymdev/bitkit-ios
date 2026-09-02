# Pubky auth

This suite covers the OS handoff into Bitkit for `pubkyauth` setup links. It stops at explicit watch-only consent and never authorizes or exports account material.

## Preconditions

- Build and run Bitkit with `E2E_BUILD`.
- Complete wallet onboarding.
- Enable Paykit UI in developer settings.
- Create a Pubky profile in Bitkit so the wallet has a local identity secret.

The journey uses a syntactically valid dummy request and does not contact its relay unless the authorization flow is completed.
