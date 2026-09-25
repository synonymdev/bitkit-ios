# Offline receive integration

This draft adds the receive UI, a provider boundary and a real provider for FFOR.
The feature stays hidden in every ordinary build: the committed dependency pin is
`synonymdev/ldk-node` 0.7.0-rc.66, which has no offline receive API, so the app
compiles with `UnavailableOfflineReceiveProvider`, the checkbox never appears and
attempts to create an offline invoice fail. Ordinary invoices are never presented
as offline invoices, and no invoice is displayed unless the node reported it Ready.

Tracking: https://github.com/synonymdev/ldk-node/issues/117

## What is wired

Three layers exist so the polling and persistence logic is testable without the
native framework:

- `OfflineReceiveProviding` (`OfflineReceiveSession.swift`) is the boundary the
  receive flow talks to. `UnavailableOfflineReceiveProvider` is the default.
- `LdkOfflineReceiveProvider` (`LdkOfflineReceiveProvider.swift`) is the real
  provider. It talks to the node only through the small `OfflineReceiveNodeClient`
  protocol, which mirrors the binding's `OfflineReceivePayment` API
  (`canReceive`, `prepare`, `status`, `cancel`) with app-side status and error enums.
  It always compiles.
- `LdkNodeOfflineReceiveClient` (`LdkNodeOfflineReceiveClient.swift`) adapts the
  generated `OfflineReceivePayment` object onto that protocol and runs every call on
  the LDK service queue. It compiles only when the `OFFLINE_RECEIVE_LOCAL_LDK`
  compilation condition is set, because the API does not exist in rc.66.

Provider behaviour:

- `canReceive(amountSats:)` calls `canReceive(amountMsat:)` and reports `false` for
  `OfflineReceiveDisabled`, `OfflineReceiveUnavailable` and `OfflineReceiveIneligible`.
- `prepareInvoice(requestId:amountSats:description:)` calls `prepare` and polls
  `status` every 0.5 s for at most 60 s until the node reports `ready(bolt11)`.
  `expired`, `settled` and `failed` throw `OfflineReceiveError.unavailable`. A timeout
  also throws `unavailable` but keeps the request identity so a retry resumes the
  same node request instead of preparing a second one. Task cancellation stops
  polling without cancelling the node request. A `ready` invoice is accepted only if
  its amount equals the request exactly and its payee is our own node id; the
  receive flow then repeats its own amount, description, network and expiry checks.
- Request identity is persisted (`UserDefaultsOfflineReceiveRequestStore`, key
  `offlineReceivePendingRequests`) as `(requestId, amountSats, description)`. After
  process death the provider looks up the stored identity for the same amount and
  description and calls `status(requestId:)` first, so a Ready invoice is recovered
  without a new `prepare`. Entries are removed on terminal states, on invalid
  invoices, on node errors during preparation and on `cancel`. A different amount
  or description gets its own identity; the previous node request is left alone.
- `cancel(requestId:)` releases the node request and forgets the identity. The
  receive UI does not call it yet.

Node configuration (`OfflineReceiveSettings.swift`, applied in
`LightningService.setup` under the compilation condition): when the developer
toggle is on, `Builder.setOfflineReceiveConfig` receives the settlement node id
(the developer override, otherwise the Blocktank LSP peer Bitkit already trusts
for the current network), the developer-entered witness node ids with
`retentionBlocks` 288 and `minimumReceipts` 0, and the binding's development
defaults: invoice expiry 3600 s, safety margin 120 s, settlement deadline 144
blocks, deadline margin 6, claim margin 20, voucher expiry 288, zero fees, poll
interval 5 s. Invalid ids are ignored rather than passed to the builder, and
without a valid settlement node nothing is configured. The builder reads the
configuration once, so a toggle change takes effect after the app restarts. The
notification extension has its own `UserDefaults` container and therefore builds
its node without the configuration.

Provider selection happens in `AppScene` through
`OfflineReceiveProviderSelection.provider()`. With the compilation condition it
returns `DeveloperGatedOfflineReceiveProvider`, which consults the toggle on every
call and otherwise behaves like the unavailable provider. Without the condition it
returns `UnavailableOfflineReceiveProvider`.

## Developer toggle

Settings > Dev Settings shows an "OFFLINE RECEIVE" section only in builds compiled
with `OFFLINE_RECEIVE_LOCAL_LDK`. It has the "Offline receive (experimental)"
toggle (default off, key `offlineReceiveExperimentalEnabled`,
accessibility id `OfflineReceiveToggle`) and, once enabled, text fields for the
settlement node id override and comma separated witness node ids. Production and
CI builds neither compile the adapter nor show the section, so the checkbox in
the receive editor remains absent unless the local binding, the toggle and a
node that reports `canReceive` all agree.

## Building against the local binding

The committed pin stays at rc.66 for CI. To build the real provider locally:

1. Prepare a local package whose directory is named `ldk-node` (SPM derives the
   override identity from the directory name), for example
   `/private/tmp/ffor-ios-ldk-node/ldk-node`, containing:
   - `Package.swift` copied from the ldk-node checkout with the binary target
     changed to `.binaryTarget(name: "LDKNodeFFI", path: "./bindings/swift/LDKNodeFFI.xcframework")`;
   - `bindings/swift/Sources/LDKNode/LDKNode.swift` from the checkout;
   - `bindings/swift/LDKNodeFFI.xcframework` unzipped from the release artifact.
2. In Xcode: File > Add Package Dependencies > Add Local, pick that directory.
   A local package with the same identity overrides the remote `ldk-node`
   dependency for that workspace session. Do not commit the resulting project or
   `Package.resolved` changes.
3. Set the compilation condition. Either pass
   `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) OFFLINE_RECEIVE_LOCAL_LDK'`
   on the `xcodebuild` command line (the same pattern as `E2E_BUILD`), or use
   `-xcconfig Configs/OfflineReceiveLocalLdk.xcconfig`, or assign that xcconfig to
   the Debug configuration of the Bitkit target in Xcode for the session.

For `xcodebuild`, a throwaway workspace outside the repository gives the same
override without editing the project:

```xml
<!-- /private/tmp/ffor-ios-local.xcworkspace/contents.xcworkspacedata -->
<?xml version="1.0" encoding="UTF-8"?>
<Workspace version = "1.0">
   <FileRef location = "absolute:/path/to/bitkit-ios/Bitkit.xcodeproj"></FileRef>
   <FileRef location = "absolute:/private/tmp/ffor-ios-ldk-node/ldk-node"></FileRef>
</Workspace>
```

```bash
xcodebuild -workspace /private/tmp/ffor-ios-local.xcworkspace -scheme Bitkit \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /private/tmp/ffor-ios-build-local \
  -clonedSourcePackagesDirPath /private/tmp/ffor-ios-spm-local \
  -xcconfig Configs/OfflineReceiveLocalLdk.xcconfig build
```

Use a separate derived data path and cloned packages directory so the rc.66
module caches of the ordinary build are not invalidated (see the FFI header
warning in `AGENTS.md`).

## Provider requirements

The provider must:

1. Check eligibility for the exact amount, including peer capability, negotiated
   channel support, channel limits and existing offline reservations. The UI's
   inbound liquidity check alone is insufficient. The node's `canReceive` is
   responsible for this; the app only converts the amount.
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
settlement deadline are distinct. These checks do not prove FFOR activation. Only
the node's `ready` status establishes that.

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

Before registering an offline invoice for display, the app checks native payment
history for a matching successful inbound BOLT11 payment. A payment event during
that lookup forces a fresh history snapshot. The final display update also checks
that the candidate still belongs to the current session and has not been retired
by a matching payment event. Missing payment history refuses display.

A prepared invoice remains visible and shareable in its QR screen after the
device disconnects or the node stops. Channel events do not replace it. The
connection overlay still covers ordinary invoices and invoice editing. Expiry
removes the prepared QR, and a matching payment event retires its display state.
Display state belongs to the current receive session; native registration and
recovery across app restarts remain provider responsibilities. Offline BOLT11 and
BIP21 strings stay in memory and never enter the ordinary receive invoice cache.

## Verification

`OfflineReceiveSessionTests` uses an injected provider to exercise capability,
liquidity boundaries, stale responses, session reset and failed activation.
`OfflineReceiveRegistrationTests` covers paid-history checks, payment and session
races, expiry and isolation from the ordinary persistent invoice cache.
`LdkOfflineReceiveProviderTests` drives `LdkOfflineReceiveProvider` with a fake
node client and a fake clock: the ready path, no polling for an immediately ready
request, the bounded timeout and retry resumption, terminal state and node error
mapping, `canReceive` mapping, identity recovery after a simulated restart
(ready, still pending, and forgotten requests), separate identities per intent,
Task cancellation, explicit cancel, amount and payee validation, the developer
gate, the `UserDefaults` store, the node configuration parser and the default
provider selection. Existing receive tests cover the ordinary invoice liquidity
rules and edit navigation. These are application contract tests, not a live FFOR
payment test.

Device validation is pending. Before enabling a production provider, verify on a
device against a settlement node that a funded receiver can prepare an invoice,
stop the app, receive a payment through the forwarding peer, restart and recover
the payment. Include expiry, offline restart, abort, replay, capacity exhaustion,
loss of the peer connection and concurrent preparation cases.
