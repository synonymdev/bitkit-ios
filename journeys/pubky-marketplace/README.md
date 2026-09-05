# Pubky marketplace wallet leg

This suite covers the two-wallet Bitkit leg of a Pubky marketplace purchase: a seller grants a
watch-only account claim, a linked buyer receives the resulting Payment Request, and the buyer pays
the request on regtest through confirmation. It does not cover marketplace browsing, Locks content
delivery, fiat payment, or Hypercolor.

## Required integration fixture

The journey needs a controlled integration fixture outside this repository. The test operator owns
the fixture state and must provide:

- A fresh Pubky testnet or isolated staging namespace reachable by both simulator wallets.
- A Paykit Server compatible with the watch-only setup contract merged in
  [`pubky/paykit-server#2`](https://github.com/pubky/paykit-server/pull/2), including a `/setup` auth
  URL whose payload carries `x-bitkit-claim=watch-only-account-v1`. Revision
  [`867fc883`](https://github.com/pubky/paykit-server/commit/867fc883125c7b89a7b712c2551619cccdfdc0f7)
  is the producer provenance used by the accepted run.
- A regtest bitcoind and Electrum/Fulcrum endpoint on the same chain. Before launching either
  wallet, publish the fixture's Fulcrum endpoint to the simulator host at
  `tcp://127.0.0.1:60001`; this is Bitkit's local-E2E default and prevents either wallet from
  retaining a taller foreign regtest tip.
- A clean seller wallet, a separate clean funded buyer wallet, and bilateral Paykit peer links at
  `bitkit/server` and `bitkit/wallet`.
- A driver that creates exactly one purchase for the buyer, reports the Payment Request id and
  delivery state, returns the derived address and expected amount, mines exactly one authorized
  block, and reports signed Paykit and marketplace completion state.

The request and endpoint must satisfy the issuer contract from iOS issue
[#713](https://github.com/synonymdev/bitkit-ios/issues/713): lowercase `btc`, a network-correct
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

## Required app changes

The full journey depends on the sibling work from the parent epic:

- [#713](https://github.com/synonymdev/bitkit-ios/issues/713) defines the issuer interop contract.
- [#714](https://github.com/synonymdev/bitkit-ios/issues/714) supplies the stable per-request Pay
  action identifier used by this journey.
- [#715](https://github.com/synonymdev/bitkit-ios/issues/715) opens the fixture's `pubkyauth` URL
  directly in Bitkit.
- [#717](https://github.com/synonymdev/bitkit-ios/issues/717) prevents an Electrum-rejected broadcast
  from reaching `SendSuccess`.

Contact payments must be enabled in General Settings and the buyer and seller must save each other
before Bitkit's `receivePrivateMessagesFromLinkedPeers()` poll can receive the request.

## Evidence contract

Capture one timestamped evidence directory per run. Record the app commit, integration revision,
both simulator identifiers, Payment Request id, transaction id, and regtest block height. Keep these
artifacts at each boundary:

| Boundary | Bitkit evidence | Integration evidence |
| --- | --- | --- |
| Watch-only claim | `PubkyAuthWatchOnlyConsent`, `PubkyAuthWatchOnlyApprove`, `PubkyAuthAuthorize`, and `PubkyAuthOK` snapshots | Setup completion and the claimed xpub/account index, with no spending key |
| Linked buyer | Enabled `ContactPaymentsToggle`, `Contact_<seller-public-key>`, and `Contact_<buyer-public-key>` snapshots | Seller and buyer peer-link state |
| Incoming request | `PaymentRequestsScreen` and `PaymentRequestRow-<payment-request-id>` snapshots showing seller, amount, and note when present | Delivery record and exact Payment Request id |
| Payment approval | `PaymentRequestPay-<payment-request-id>`, `ReviewAmount`, and `ReviewContactRecipient` snapshots | Derived regtest address and expected amount |
| Broadcast | `SendSuccess` snapshot and buyer activity details | Transaction in the fixture mempool with an amount-matched output |
| Confirmation | `StatusConfirmed`, `ActivityAmount`, and `ActivityTxDetails` snapshots | Transaction id at one or more confirmations and completed purchase status |

`SendSuccess` proves backend acceptance, not confirmation. The integration fixture's chain, signed
Paykit state, and marketplace state are the confirmation authority. Android uses a transient request
sheet; the iOS journey opens the persistent `PaymentRequestsScreen` before selecting the same
request-row and per-request Pay identifiers.

## Accepted exact-head run from 2026-09-02

The final iOS acceptance replay used integration merge
`a87d298939b868b899a1f1139ce84a5227703a51`, composed from merged Pay-selector head
`70cd26346c6a539f792564e2e9bddb41cc00eecc` and this journey's pre-run documentation head
`c0cf2d553b1cdcf6dd1bba6d8865a80292b4d7e8`. Its production tree was identical to the selector
head. The installed Bitkit dylib SHA-256 was
`6c5a1be9db1f5985d92629021db7836befd0a3d31c0db638ea284988b123467c`.

- The controlled seller identity was
  `pubkyhbn4tahj71yzpmtarz5amtqqf5fmicdd7rs8ao448tzaujdapfiy`. The fresh buyer simulator was
  `DED250A8-2952-42B9-B585-6654E361C87A`, with identity
  `pubkyyrnr7smimj8fohmwk84jdoyn6xxdsgo175fu4xd844f1x3xk3xao`.
- The seller setup retained watch-only account index `1` without Bitcoin spending authority. The
  buyer enabled `ContactPaymentsToggle`, saved the seller as
  `Contact_pubkyhbn4tahj71yzpmtarz5amtqqf5fmicdd7rs8ao448tzaujdapfiy`, and linked at
  `bitkit/wallet` with failure count `0`.
- Funding transaction `a57ec0f1b0ebaf493cb98799d3fbf126ecefa9f7f28dcb4f4f14386324b9faac`
  paid the fresh buyer exactly 1,000,000 sats. One funding block advanced the shared chain to height
  `16402` with tip `6b3dcd34ae81b07a064a1c3497ff47f60f2cda3cb5b27fc5b94777b829c6b6f1`.
- Bundle `SSK4TAEXNRSY2RA8E0FCNVXDE4` produced request
  `5f07c465-dc67-42ce-96a0-4209e5389618` for `0.00015000 btc`. Endpoint
  `btc-regtest-p2wpkh` contained JSON value
  `bcrt1qhlqp9nv4awtzl6psdqmuavanlxzyaemv3pce60`.
- `PaymentRequestRow-5f07c465-dc67-42ce-96a0-4209e5389618` showed 15,000 sats and exposed
  `PaymentRequestPay-5f07c465-dc67-42ce-96a0-4209e5389618`. Review preserved 15,000 sats,
  `ReviewContactRecipient` resolved to `hbn4...pfiy`, and the 143-sat fee and enabled `GRAB` were
  visible.
- Exactly one swipe reached `SendSuccess` and broadcast
  `2822f6b43aebeb228e0bfe96c1b201cf41e0ed46a677d704403dc629b09d6f2a`. Output zero paid the
  request address exactly 15,000 sats, output one returned 984,857 sats, and the fee was 143 sats.
- Before mining, the transaction was the only mempool entry, signed Paykit state was
  `detected/0/true`, and the Locks bundle remained pending. Exactly one authorized block,
  `6235eff06b00ed2b736635913e76269cd6524c4fed80f247d244102806816aed`, advanced the chain to
  height `16403`.
- Signed Paykit state then reached `confirmed/1/true`, the Locks bundle completed without a failure,
  guarded content returned HTTP 200, and the mempool was empty. Bitkit independently synchronized
  to the same height and tip.
- The buyer displayed `StatusConfirmed`, a 15,000-sat payment, a 143-sat fee, the seller contact,
  and the exact transaction under `ActivityTxDetails`. Request history retained exactly
  `PaymentRequestRow-5f07c465-dc67-42ce-96a0-4209e5389618` without Pay or Dismiss actions.
- The sanitized replay video SHA-256 is
  `ec6f0819c9e4e4066e8969f092328615bb286925599b6f92c733eba4b999c122`.
