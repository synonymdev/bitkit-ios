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
[`BitcoinErrorLog/pubky-marketplace/payments-env`](https://github.com/BitcoinErrorLog/pubky-marketplace/tree/0259d994967961cb0b972eba2f11a567d7376dd7/payments-env).
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
| Incoming request | `PaymentRequestsSheet` and `PaymentRequestRow-<payment-request-id>` snapshots showing seller, note, and amount | Delivery record and exact Payment Request id |
| Payment approval | `PaymentRequestPay-<payment-request-id>`, `ReviewAmount`, and `ReviewUri` snapshots | Derived regtest address and expected amount |
| Broadcast | `SendSuccess` snapshot and buyer activity details | Transaction in the fixture mempool with an amount-matched output |
| Confirmation | Confirmed buyer activity snapshot | Transaction id at one or more confirmations and completed purchase status |

`SendSuccess` is evidence of backend acceptance, not confirmation. The fixture's chain and purchase
status are the confirmation authority.

## Baseline from 2026-09-02

The journey branch at `32bd6948` was built for two freshly erased simulators with Paykit UI enabled
against fixture commit `0259d994`. The seller completed the watch-only consent and exact Paykit
capability authorization through `PubkyAuthOK`; fixture setup completed without spending authority.
The buyer received 100,000 regtest sats, both wallets enabled contact payments, saved each other,
and linked the seller's `bitkit/server` and `bitkit/wallet` receivers.

Paykit marked two iOS-targeted requests delivered, with Payment Request ids
`43c0f7d4-92f7-4ec1-b9c4-5cff67d72381` and `436a1fb4-9109-4a8f-bcae-6c700e218634`. The buyer SDK
received both as linked, proposed payer records for 15,000 sats, but the fixture emitted uppercase
`BTC` and `btc-bitcoin-p2wpkh`. Those values violate the issuer contract above, so Bitkit correctly
excluded the records from actionable requests and did not present `PaymentRequestsSheet`. A
coordinated Android buyer reproduced the same no-request result from a separately delivered
fixture request. The baseline therefore stops at the issuer-contract assertion; approval,
broadcast, and confirmation remain pending a fixture that emits the documented regtest contract.
