# Pubky marketplace wallet leg

This suite covers the two-wallet Bitkit leg of a Pubky marketplace purchase: a seller grants a
watch-only account claim, a linked buyer receives the resulting Payment Request, and the buyer pays
the request on regtest through confirmation. It does not cover marketplace browsing, Locks content
delivery, fiat payment, or Hypercolor.

## Required external fixture

The journey needs a controlled marketplace fixture outside this repository. The fixture owns all
server-side state and must provide:

- A fresh Pubky testnet or isolated staging namespace reachable by both simulator wallets.
- A Paykit Server with the marketplace wallet-interop fixes and a `/setup` flow whose auth URL
  carries `x-bitkit-claim=watch-only-account-v1`.
- A regtest bitcoind and Electrum/Fulcrum endpoint on the same chain. The endpoint must be configured
  in both wallets before first launch so neither wallet retains a taller foreign regtest tip. The
  reference fixture keeps Fulcrum internal, so a live wallet run must publish or proxy that endpoint
  to the simulator host.
- A clean seller wallet, a separate clean funded buyer wallet, and the seller Pubky public key.
- A marketplace driver that can create one purchase for the buyer, expose its Payment Request id,
  report Paykit delivery, return the derived on-chain address and expected amount, mine one block,
  and report the transaction and purchase status.

The request and endpoint must satisfy the issuer contract from iOS issue
[#713](https://github.com/synonymdev/bitkit-ios/issues/713): lowercase `btc`, a network-correct
`btc-regtest-*` endpoint identifier, and a JSON endpoint payload with a non-empty string `value`.
The fixture must keep watch-only account material and spending authority separate. Evidence must
show the claimed account xpub and account index while omitting wallet seed material and tokens.

The reference implementation is
[`BitcoinErrorLog/pubky-marketplace/payments-env`](https://github.com/BitcoinErrorLog/pubky-marketplace/tree/ed03a32ecfe02deab40ad10ae1bac7fa18465c10/payments-env).
Its `scripts/verify.sh` already proves the Locks, Paykit, Pubky, bitcoind, and Fulcrum protocol path.
For this journey, the seller wallet replaces `paykit-companion-auth` and the buyer wallet replaces
`paykit-reader-demo`; the other fixture roles remain unchanged.

## Required app changes

The full journey depends on the sibling work from the parent epic:

- [#713](https://github.com/synonymdev/bitkit-ios/issues/713) defines the issuer interop contract.
- [#714](https://github.com/synonymdev/bitkit-ios/issues/714) supplies the stable per-request Pay
  action identifier used by this journey.
- [#715](https://github.com/synonymdev/bitkit-ios/issues/715) opens the fixture's `pubkyauth` URL
  directly in Bitkit.
- [#717](https://github.com/synonymdev/bitkit-ios/issues/717) prevents an Electrum-rejected broadcast
  from reaching `SendSuccess`.

The linked-contact prerequisite is existing Paykit behavior: contact payments must be enabled in
General Settings and the buyer and seller must save each other before Bitkit's
`receivePrivateMessagesFromLinkedPeers()` poll can receive the request.

## Evidence contract

Capture one timestamped evidence directory per run. Record the app commit, fixture commit, both
simulator identifiers, Payment Request id, transaction id, and regtest block height. Keep these
artifacts at each boundary:

| Boundary | Bitkit evidence | Fixture evidence |
| --- | --- | --- |
| Watch-only claim | `PubkyAuthWatchOnlyConsent`, `PubkyAuthWatchOnlyApprove`, `PubkyAuthAuthorize`, and `PubkyAuthOK` snapshots | Setup completion and the claimed xpub/account index, with no spending key |
| Linked buyer | Enabled `ContactPaymentsToggle`, `Contact_<seller-public-key>`, and `Contact_<buyer-public-key>` snapshots | Seller and buyer peer-link state |
| Incoming request | `PaymentRequestsSheet` and `PaymentRequestRow-<payment-request-id>` snapshots showing seller, amount, and note when present | Delivery record and exact Payment Request id |
| Payment approval | `PaymentRequestPay-<payment-request-id>`, `ReviewAmount`, and `ReviewContactRecipient` snapshots | Derived regtest address and expected amount |
| Broadcast | `SendSuccess` snapshot and buyer activity details | Transaction in the fixture mempool with an amount-matched output |
| Confirmation | Confirmed buyer activity snapshot | Transaction id at one or more confirmations and completed purchase status |

`SendSuccess` is evidence of backend acceptance, not confirmation. The fixture's chain and purchase
status are the confirmation authority.

## Accepted corrected iOS run from 2026-09-02

The complete journey passed on iOS app commit `c3791bbf7cccd9dfdd94f85081330ebe2d480692`
against fixture commit `ed03a32ecfe02deab40ad10ae1bac7fa18465c10`, Paykit Server revision
`867fc883125c7b89a7b712c2551619cccdfdc0f7`, and Paykit revision
`6b241878a9bba5cecea919c0298c3f90624be6ff`. The Paykit Server image was
`sha256:2e5c2e8391a4a9f60dfaed3326fce0b772f01e81b4a51b69cbf08c0b02bd89e8`.

- Seller simulator: `B379B7A4-715A-427F-8CB6-A6479BC73050`; Pubky
  `pubkyhbn4tahj71yzpmtarz5amtqqf5fmicdd7rs8ao448tzaujdapfiy`.
- Buyer simulator: `1B8D53BA-43F9-4799-AC0D-32EFDA4BDAF6`; Pubky
  `pubkysqy1tx5poq5djne846r4rfbkca8ggmru9jp8d34tbjp74ngtzxno`.
- The seller approved the watch-only claim and exact Paykit capabilities. The fixture persisted
  account index `1` (`m/84h/1h/1h`) and its account tpub without Bitcoin spending authority.
- Both wallets enabled `ContactPaymentsToggle` and displayed reciprocal `Contact_<public-key>`
  rows before the fixture reported the buyer `Linked` at `bitkit/wallet` with failure count `0`.
- Buyer funding transaction `0baf24337a58449816a18f0bb984e9dbc993fd9cb1bbf4391aff333280bcb908`
  paid exactly 1,000,000 sats and was confirmed in block
  `642c3864f623d376d04dbc1c6fba5b64f6e72cfcdbb6029fa7d0ade7dc24383f` at height `16400`.
- Canonical request `60281cab-4914-40e9-979a-6572eebe69d6` used `0.00015000 btc`, endpoint identifier
  `btc-regtest-p2wpkh`, and JSON endpoint value
  `bcrt1qkhvgdehsp9y54tqp60f74phsqjjl77anrdmawn`. Its note was absent.
- `PaymentRequestsSheet` showed Seller and 15,000 sats. The approval retained 15,000 sats,
  `ReviewContactRecipient` resolved to Seller, and the 143-sat fee and enabled `GRAB` were visible.
- Exactly one authorized swipe reached `SendSuccess` and broadcast transaction
  `f15eb143e91904bac0b6d966627f60a37eb14862a96f7455a7ae00598ddb5150`. Output zero paid exactly
  15,000 sats to the request address, output one returned 984,857 sats, and the fee was 143 sats.
- Before mining, the transaction was the only mempool entry, Paykit reported `detected/0/true`, and
  the Locks bundle remained pending. Exactly one block,
  `4d607bf79dd4d94624f1f4fc6f8e90a38a25a474e9aa08298f85f971ecc2e0fc`, advanced the chain to
  height `16401`; Paykit then reported `confirmed/1/true`, the Locks bundle completed without
  failure, and the mempool was empty.
- The buyer displayed `StatusConfirmed`, `ActivityAmount` with a 15,000-sat payment and 143-sat fee,
  `ActivityTxDetails`, and Seller. Request history retained exactly
  `PaymentRequestRow-60281cab-4914-40e9-979a-6572eebe69d6` without Pay or Dismiss actions.

Android replays exercised the same corrected fixture and shared protocol vocabulary. They are
diagnostic cross-platform evidence and are not the accepted iOS journey execution above.

## Diagnostic baseline from 2026-09-02

The journey branch at `32bd6948` was built for two freshly erased simulators with Paykit UI enabled
against fixture commit `0259d994`. The preserved app evidence confirms the final `PubkyAuthOK`
authorization success. The fixture's immutable protocol evidence independently passed all 15
verification steps.

An exploratory two-wallet run subsequently observed seller setup, a funded buyer, bilateral
contacts, linked `bitkit/server` and `bitkit/wallet` receivers, and delivered requests. That run did
not preserve the full boundary artifacts required above for consent and approval, exact
capabilities, both toggles and contact rows, claimed account details, or raw SDK and outbox state.
Those observations are diagnostic context, not passed journey boundaries.

Paykit marked two iOS-targeted requests delivered, with Payment Request ids
`43c0f7d4-92f7-4ec1-b9c4-5cff67d72381` and `436a1fb4-9109-4a8f-bcae-6c700e218634`. The buyer SDK
received both as linked, proposed payer records for 15,000 sats, but the fixture emitted uppercase
`BTC` and `btc-bitcoin-p2wpkh`. Those values violate the issuer contract above, so Bitkit correctly
excluded the records from actionable requests and did not present `PaymentRequestsSheet`. A
coordinated Android buyer reproduced the same no-request result from a separately delivered
fixture request. The diagnostic baseline therefore stops at the issuer-contract assertion; the
accepted corrected iOS run above supersedes its incomplete boundary coverage.

The corrected fixture work is tracked in
[`BitcoinErrorLog/pubky-marketplace#1`](https://github.com/BitcoinErrorLog/pubky-marketplace/issues/1).
