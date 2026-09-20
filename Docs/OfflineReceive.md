# Offline receive integration

This draft adds the receive UI and a provider boundary for FFOR. It does not enable
offline payments with the current LDK Node dependency. The live provider is
`UnavailableOfflineReceiveProvider`, so the checkbox remains hidden and attempts
to create an offline invoice fail. Ordinary invoices are never presented as
offline invoices.

Tracking: https://github.com/synonymdev/ldk-node/issues/117

## Provider requirements

Replace the unavailable provider through `WalletViewModel` initialization only
after the node and its channel peer support the FFOR protocol. The provider must:

1. Check eligibility for the exact amount, including peer capability, negotiated
   channel support, channel limits and existing offline reservations. The UI's
   inbound liquidity check alone is insufficient.
2. Recheck and reserve capacity atomically when preparing an invoice. The
   eligibility check is advisory and does not reserve funds.
3. Perform FFOR setup, durable registration and activation. Return
   `PreparedOfflineInvoice` only after the protocol permits publishing it and all
   local recovery state is durable. Ordinary BOLT11 creation is not a fallback.
4. Safely handle concurrent requests, cancellation, retries, expiry and failures
   without orphaning reservations or exposing unactivated invoices. Treat
   `requestId` as an idempotency key. A retry must recover the original result,
   including when its reservation has already consumed inbound liquidity.
5. Recover pending registrations after restart and reconcile settlement through
   the wallet's normal payment and activity paths.

The native provider chooses the invoice expiry and offline settlement window from
its negotiated policy. The app does not request or assume a duration. It parses
the returned BOLT11 and checks its exact amount, direct description, network and
expiry, then uses that signed expiry for display. Invoice expiry and the protocol's
settlement deadline are distinct. These checks do not prove FFOR activation. The
node provider must establish that guarantee.

The pinned LDK Node version has no FFOR registration or activation API. Rust
Lightning channel support, the forwarding peer implementation, durable lifecycle
management and updated mobile bindings are still prerequisites. No generated
node API or production provider is assumed by this draft.

## Receive behavior

The checkbox uses the shared `ReceiveOffline` accessibility identifier and reads
"Receive Offline". It appears in Auto and Spending edits only after the running
node's provider confirms a positive amount within current ready inbound
liquidity. Savings and hardware-only edits never offer it.

Changing the amount clears selection. Losing capacity or provider eligibility
before preparation also clears selection. An attempted preparation keeps its
identity and selected mode for retries of the same amount and note,
including after a lost activation response. A changed request or new session gets
a new identity. Discarding a stale result does not cancel durable node state.
Late eligibility responses cannot replace the current
amount's result or restore a closed session. A fresh receive sheet resets the
selection.

Invoice generation snapshots the selected mode. Background refresh and expiry
use that same mode, and failed offline preparation cannot silently create an
ordinary invoice or retain a stale QR. A newer refresh or edit prevents an older
request from publishing its invoice.

A prepared invoice remains visible and shareable in its QR screen after the
device disconnects or the node stops. Channel events do not replace it. The
connection overlay still covers ordinary invoices and invoice editing. Expiry
removes the prepared QR, and a matching payment event retires its display state.
Display state belongs to the current receive session; native registration and
recovery across app restarts remain provider responsibilities.

## Verification

`OfflineReceiveSessionTests` uses an injected provider to exercise capability,
liquidity boundaries, stale responses, session reset and failed activation.
Existing receive tests cover the ordinary invoice liquidity rules and edit
navigation. These are application contract tests, not a live FFOR payment test.

Before enabling a production provider, verify a funded receiver can prepare an
invoice, stop the app, receive a payment through the forwarding peer, restart and
recover the payment. Include expiry, offline restart, abort, replay, capacity
exhaustion, loss of the peer connection and concurrent preparation cases.
