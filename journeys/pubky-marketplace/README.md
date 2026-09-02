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
  in both wallets before first launch so neither wallet retains a taller foreign regtest tip.
- A clean seller wallet, a separate clean funded buyer wallet, and the seller Pubky public key.
- A marketplace driver that can create one purchase for the buyer, expose its Payment Request id,
  report Paykit delivery, return the derived on-chain address and expected amount, mine one block,
  and report the transaction and purchase status.

The request and endpoint must satisfy the issuer contract from iOS issue
[#713](https://github.com/synonymdev/bitkit-ios/issues/713): lowercase `btc`, a network-correct
`btc-regtest-*` endpoint identifier, and a JSON endpoint payload with a non-empty string `value`.
The fixture must keep watch-only account material and spending authority separate. Evidence must
show the claimed account xpub and account index while omitting wallet seed material and tokens.

The previously proven staging fixture is documented in
`BitcoinErrorLog/pubky-payment-rails/docs/wallet-leg.md`. Access to that repository, or an equivalent
fixture implementing the requirements above, is required to execute the journey.

## Required app changes

The full journey depends on the sibling work from the parent epic:

- [#713](https://github.com/synonymdev/bitkit-ios/issues/713) defines the issuer interop contract.
- [#714](https://github.com/synonymdev/bitkit-ios/issues/714) supplies the stable per-request Pay
  action identifier used by this journey.
- [#715](https://github.com/synonymdev/bitkit-ios/issues/715) opens the fixture's `pubkyauth` URL
  directly in Bitkit.
- [#717](https://github.com/synonymdev/bitkit-ios/issues/717) prevents an Electrum-rejected broadcast
  from reaching `SendSuccess`.

The linked-contact prerequisite is existing Paykit behavior: the buyer must save the seller before
Bitkit's `receivePrivateMessagesFromLinkedPeers()` poll can receive the request.

## Evidence contract

Capture one timestamped evidence directory per run. Record the app commit, fixture commit, both
simulator identifiers, Payment Request id, transaction id, and regtest block height. Keep these
artifacts at each boundary:

| Boundary | Bitkit evidence | Fixture evidence |
| --- | --- | --- |
| Watch-only claim | `PubkyAuthWatchOnlyConsent`, `PubkyAuthWatchOnlyApprove`, `PubkyAuthAuthorize`, and `PubkyAuthOK` snapshots | Setup completion and the claimed xpub/account index, with no spending key |
| Linked buyer | `Contact_<seller-public-key>` snapshot | Seller and buyer peer-link state |
| Incoming request | `PaymentRequestsSheet` and `PaymentRequestRow-<payment-request-id>` snapshots showing seller, note, and amount | Delivery record and exact Payment Request id |
| Payment approval | `PaymentRequestPay-<payment-request-id>`, `ReviewAmount`, and `ReviewUri` snapshots | Derived regtest address and expected amount |
| Broadcast | `SendSuccess` snapshot and buyer activity details | Transaction in the fixture mempool with an amount-matched output |
| Confirmation | Confirmed buyer activity snapshot | Transaction id at one or more confirmations and completed purchase status |

`SendSuccess` is evidence of backend acceptance, not confirmation. The fixture's chain and purchase
status are the confirmation authority.

## Baseline from 2026-09-02

The current implementation was built from `004a1082` on a freshly erased iPhone 17 Pro Max
simulator with Paykit UI enabled. A new wallet and Pubky profile reached the in-app scanner/paste
handoff used by the prior wallet-leg proof. The run stopped before watch-only approval because the
staging fixture repository and its setup URL were unavailable to the runner. This establishes the
app-side baseline without claiming an end-to-end pass.
