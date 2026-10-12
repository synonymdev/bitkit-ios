# Pubky marketplace wallet leg

This suite covers the two-wallet Bitkit leg of a Pubky marketplace purchase: a seller grants
Paykit access, a watch-only account and a marketplace write grant, a linked buyer receives the
Payment Request, and the buyer pays the request on regtest through confirmation. It does not cover
marketplace browsing, Locks content delivery, fiat payment, or Hypercolor.

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
- A marketplace grant request for the seller wallet: a Pubky grant auth URL from requester `locks.app` for
  `/pub/app.locks/` with READ, WRITE access, and a report of the approved grant and the setup completion time
  for the identity that approved both requests.
- A driver that creates exactly one purchase for the buyer, reports the Payment Request id and
  delivery state, returns the derived address and expected amount, mines exactly one authorized
  block, and reports signed Paykit and marketplace completion state.

The request and endpoint must satisfy the
[issuer contract](../../Docs/paykit-issuer-interoperability.md): lowercase `btc`, a network-correct
`btc-regtest-*` endpoint identifier, and a JSON endpoint payload with a non-empty string `value`.
The fixture must keep watch-only account material and spending authority separate. Paykit Server
keeps the claimed account xpub to itself, so the fixture cannot report it; evidence records the setup
completion and the marketplace grant instead, and omits wallet seed material and tokens.

The [bitkit-docker](https://github.com/synonymdev/bitkit-docker) `marketplace` profile provides this fixture
([`docs/pubky-marketplace.md`](https://github.com/synonymdev/bitkit-docker/blob/main/docs/pubky-marketplace.md)):

- `./pubky-marketplace setup-url` prints the setup request with its `ios_url`, which opens through
  `xcrun simctl openurl <simulator-id> '<ios_url>'`; `setup-wait <flow>` waits for the setup to complete.
- `./pubky-marketplace seller-auth` prints the marketplace grant request as its first JSON line and waits for the
  approval. iOS has no deep link for this request: put its `auth_url` on the simulator clipboard with
  `printf %s '<auth_url>' | xcrun simctl pbcopy <simulator-id>`, then in the seller wallet use Scan QR Code
  and Paste QR Code (E2E builds also offer Enter QRCode String). The request goes through the testnet relay on
  `localhost:15412` and expires after about five minutes, so start it at that step.
- `./pubky-marketplace info` reports `bitkit_seller.marketplace_grant` and `bitkit_seller.setup_completed_at`,
  which stays null until `setup-wait` has seen the setup complete.

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
| Combined claim | `PubkyAuthWatchOnlyConsent`, `PubkyAuthWatchOnlyApprove`, `PubkyAuthPaykitAccess`, `PubkyAuthAuthorize`, and `PubkyAuthOK` snapshots | Setup completion for the seller identity, with no spending key |
| Marketplace grant | Authorization screen with the single `/pub/app.locks` row from `locks.app`, `PubkyAuthAuthorize`, and `PubkyAuthOK` snapshots | `bitkit_seller.marketplace_grant` and a non-null `bitkit_seller.setup_completed_at` |
| Linked buyer | Enabled `ContactPaymentsToggle`, `Contact_<seller-public-key>`, and `Contact_<buyer-public-key>` snapshots | Seller and buyer peer-link state |
| Incoming request | `ReviewAmount`, `PaymentRequestsBell`, `PaymentRequestsSheet`, and `PaymentRequestRow-<payment-request-id>-one-time` snapshots showing the automatic review, seller, amount, and note when present | Delivery record and exact Payment Request id |
| Payment approval | `PaymentRequestPay-<payment-request-id>`, `ReviewAmount`, and `ReviewContactRecipient` snapshots | Derived regtest address and expected amount |
| Broadcast | `SendSuccess` snapshot and buyer activity details | Transaction in the fixture mempool with an amount-matched output |
| Confirmation | `StatusConfirmed`, `ActivityAmount`, and `ActivityTxDetails` snapshots | Transaction id at one or more confirmations and completed purchase status |

`SendSuccess` proves backend acceptance, not confirmation. The integration fixture's chain, signed
Paykit state, and marketplace state are the confirmation authority. Both platforms open fresh
requests in payment review automatically, dismiss that review, and open `PaymentRequestsSheet` from
`PaymentRequestsBell`; iOS uses a downward swipe from the sheet drag indicator instead of Android system back.
