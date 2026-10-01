# Pubky marketplace wallet leg

This suite covers the two-wallet Bitkit leg of a Pubky marketplace purchase: a seller grants
Paykit access and a watch-only account, a linked buyer receives the Payment Request, and the buyer pays
the request on regtest through confirmation. It does not cover marketplace browsing, Locks content
delivery, fiat payment, or Hypercolor.

## Required integration fixture

The journey needs a controlled integration fixture outside this repository. The test operator owns
the fixture state and must provide:

- A fresh Pubky testnet or isolated staging namespace reachable by both simulator wallets.
- A Paykit Server using the same shared-runtime SDK and the
  [companion-claim contract](../../Docs/pubky-auth-companion-claims.md), including a `/setup` auth
  URL whose payload requests `x-bitkit-claim=paykit-access-v1.watch-only-account-v1`.
- A regtest bitcoind and Electrum/Fulcrum endpoint on the same chain. Before launching either
  wallet, publish the fixture's Fulcrum endpoint to the simulator host at
  `tcp://127.0.0.1:60001`; this is Bitkit's local-E2E default and prevents either wallet from
  retaining a taller foreign regtest tip.
- A clean seller wallet, a separate clean funded buyer wallet, and an identity-wide Paykit link
  between them. The seller's Bitkit and Paykit Server share that identity's state.
- A driver that creates exactly one purchase for the buyer, reports the Payment Request id and
  delivery state, returns the derived address and expected amount, mines exactly one authorized
  block, and reports signed Paykit and marketplace completion state.

The request and endpoint must satisfy the
[issuer contract](../../Docs/paykit-issuer-interoperability.md): lowercase `btc`, a network-correct
`btc-regtest-*` endpoint identifier, and a JSON endpoint payload with a non-empty string `value`.
The fixture must keep watch-only account material and spending authority separate. Evidence records
the claimed account xpub and account index while omitting wallet seed material and tokens.

Build and run each clean simulator against that endpoint before its first launch:

```bash
xcodebuildmcp simulator build-and-run --simulator-id <simulator-id> \
  --extra-args "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) E2E_BUILD \
E2E_BACKEND=local E2E_NETWORK=regtest \
E2E_HOMESERVER_PUBKY=<homeserver-pubky>"
```

No stored Electrum override is required: `E2E_BUILD` with the local backend resolves Electrum to
`tcp://127.0.0.1:60001`. Repeat the command for the seller and buyer simulator identifiers.

## Wallet setup

Before opening the fixture setup auth URL, use the header profile button and Create path to give
each wallet a Pubky identity. A Ring identity works when its root secret is available through
shared Keychain. Contact payments must then be enabled in General Settings, and the buyer
and seller must save each other before Bitkit's `receivePrivateMessagesFromLinkedPeers()` poll can
receive the request.

## Companion approval checks

`paykit-only-approval.xml` and `paykit-reconnect.xml` cover consent and cancellation
without delivering secrets. Open the fixture's `bitkit://pubky-auth/setup` URL with
`xcrun simctl openurl <simulator-id> "<url>"`.

For successful delivery, use a controlled live relay. Verify a Paykit-only recipient
receives the current Paykit key/generation but no account material, and that no account
is allocated. For reconnect, the server requests only Paykit access for the existing
creator. Verify setup preserves its xpub, index, tracking, pending invoices, and address allocation. Do not
record secret-bearing URLs or Paykit keys in evidence.

## Periodic payout detection

Use separate seller and buyer devices. Before creating the purchase, return the seller to Home,
wait for any startup or foreground-triggered full-wallet sync to finish, and record its balance.
Keep the seller app active and the device awake while completing the purchase on the buyer device.
Do not background, restart, or manually refresh the seller before the payout appears. Capture
seller lifecycle and sync logs from before purchase creation through payout detection, alongside
the balance change and received activity for the fixture transaction. If the seller is resumed or
restarted during that interval, the run does not prove periodic payout detection and must be repeated.

## Evidence contract

Capture one timestamped evidence directory per run. Record the app commit, integration revision,
both simulator identifiers, Payment Request id, transaction id, and regtest block height. Keep these
artifacts at each boundary:

| Boundary | Bitkit evidence | Integration evidence |
| --- | --- | --- |
| Combined claim | `PubkyAuthWatchOnlyConsent`, `PubkyAuthWatchOnlyApprove`, `PubkyAuthPaykitAccess`, `PubkyAuthAuthorize`, and `PubkyAuthOK` snapshots | Setup completion and the claimed xpub/account index, with no spending key |
| Linked buyer | Enabled `ContactPaymentsToggle`, `Contact_<seller-public-key>`, and `Contact_<buyer-public-key>` snapshots | Seller and buyer peer-link state |
| Incoming request | `ReviewAmount`, `PaymentRequestsBell`, `PaymentRequestsSheet`, and `PaymentRequestRow-<payment-request-id>-one-time` snapshots showing the automatic review, seller, amount, and note when present | Delivery record and exact Payment Request id |
| Payment approval | `PaymentRequestPay-<payment-request-id>`, `ReviewAmount`, and `ReviewContactRecipient` snapshots | Derived regtest address and expected amount |
| Broadcast | `SendSuccess` snapshot and buyer activity details | Transaction in the fixture mempool with an amount-matched output |
| Confirmation | `StatusConfirmed`, `ActivityAmount`, and `ActivityTxDetails` snapshots | Transaction id at one or more confirmations and completed purchase status |

`SendSuccess` proves backend acceptance, not confirmation. The integration fixture's chain, signed
Paykit state, and marketplace state are the confirmation authority. Both platforms open fresh
requests in payment review automatically, dismiss that review, and open `PaymentRequestsSheet` from
`PaymentRequestsBell`; iOS uses a downward swipe from the sheet drag indicator instead of Android system back.
