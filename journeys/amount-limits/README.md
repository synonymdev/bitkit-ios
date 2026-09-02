# Amount-limit journeys

These journeys exercise the "block number pad input exceeding the max/available amount" behaviour.
The same `AmountInputViewModel` cap + `maxExceededCount` effect path backs all four amount-entry
screens (Send, Transfer→Spending, Receiving capacity, External node).

## What the feature does
- Typing a digit that would push the amount **over the cap is rejected** — the display stays at the
  largest value still within the cap (e.g. tapping `9` repeatedly stops at `9 999` when the cap is
  `98 064`, because `99 999` would exceed it).
- A short **warning toast** is emitted on the first rejected keypress.
- **Delete is always allowed**, even when sitting at the cap.

## Mandatory setup
1. **Fund a real, positive available balance first.** With `0` available, the cap falls back to the
   global maximum, so nothing gets blocked and the journeys silently pass for the wrong reason.
   - Get an on-chain (Savings) address from Receive → Show Details.
   - Fund and mine via the sibling Android checkout's helper, then wait for the balance to sync:
     `../bitkit-android/lsp POST /regtest/chain/deposit '{"address":"<addr>","amountSat":100000}'`
     then `../bitkit-android/lsp POST /regtest/chain/mine '{"count":3}'`. `mine` prints nothing on
     success — that is not a failure. There is no iOS copy of that helper yet — see #694 and the
     top-level README.
2. **Transfer/Spending and Receiving-capacity flows need the node connected to the LSP** so a real
   max can be quoted. On the Spending amount screen the max starts at `0` behind a spinner — wait
   for it to populate before typing.
3. **The external-node flow needs a reachable Lightning peer.** The staging LSP node works
   (`../bitkit-android/lsp GET /info` for its id/host/port).

## Gotchas
- **The cap can be lower than the visible "Available".** Fee and channel reserves mean e.g. Available
  `99 890` but a spending max of `98 064`. Assert "does not exceed the **stated maximum**", not
  "Available".
- **Do not assert Continue is disabled when over the max.** The input is *capped* rather than left in
  an over-max state, so the capped value is valid and Continue stays **enabled**.
- Toasts are short-lived (`Toast.visibilityTimeShort`) and will have faded before a snapshot
  round-trip completes. Assert one with `xcodebuildmcp ui-automation wait-for-ui` on its identifier
  (`SendAmountExceededToast`, `SpendingAmountExceededToast`, `SpendingAdvancedExceededToast`,
  `ExternalAmountExceededToast`) immediately after the over-max keypress.
- Prefer `snapshot-ui` and tap elements by identifier (`N9`, `NRemove`) over screen coordinates.

## Verified behaviour

All three walked on an iPhone 17 simulator against the stag0 regtest backend. **Send caps by
rejecting the keypress while the two transfer screens snap to the maximum, so assert "does not exceed
the stated maximum" — never a specific value:**

| Screen | Cap | Nine taps on `N9` | After one `NRemove` |
| --- | --- | --- | --- |
| Send | 297 393 | **99 999** — the largest all-9s value still under the cap | 9 999 |
| Transfer → Spending | 296 522 | **296 522** — clamped to the max exactly | 29 652 |
| Transfer → Spending | 22 016 | **22 016** — same shape, a later run on a wallet with less LSP headroom | 2 201 |
| Receiving capacity | 564 | **564** — clamped to the max exactly | 56 |

The cap column is whatever that screen enforces, not the wallet balance: for the two transfer rows it
is the settled maximum, and it moves with LSP headroom between runs. Assert the shape, never a value.
The receiving-capacity row is the behaviour PR #686 adds — Android leaves `99` there, because it
rejects the third keypress instead of snapping.

On Send and Transfer → Spending, Continue stays enabled throughout: the cap is applied to the input
rather than leaving it in an invalid state. On the receiving-capacity screen Continue can still be
disabled at the cap, because it also enforces a minimum — see the `Min` > `Max` note below. The
exceeded toasts fire on the first rejected keypress and are gone well before a snapshot round-trip
returns — race a `wait-for-ui` on the toast identifier against the taps.

The Transfer → Spending max populates from the on-chain balance and cached Blocktank info, so the
screen is reachable and cappable even with the regtest backend down. That is *not* a substitute for
a real LSP quote: without one the numbers are not the ones a real transfer would use.

### Two things the walk turned up

**The settling window is shorter than a snapshot round-trip.** `isSettlingAdvancedCapacity` disables
the number pad and Continue for exactly as long as the budget read and the LSP quotes take, and
against a warm stag0 LSP that is under a second — eight back-to-back snapshots raced against the
Advanced tap all came back with the pad already enabled. The gate is real (`NumberPad(isDisabled:)`
is wired to it, and disabled buttons drop out of the snapshot's Targets list, which is how the
Spending amount screen's own spinner is visible), but do not expect to catch it here. Treat
"already settled" as a pass.

**`Min` can exceed `Max` once LSP headroom runs out.** On a wallet with two existing Blocktank
channels the walk found `SpendingAdvancedMin` at 77 984 and `SpendingAdvancedMax` at 564 — the
minimum is derived from the client balance, the maximum from what is left of the LSP's channel-size
cap, and nothing reconciles them. Continue then stays disabled at every capacity, so the journey's
tail (Continue → order created) cannot be walked. That is a property of the regtest LSP allocation,
not of this PR; close a channel to free headroom, or accept that the run covers the cap behaviour
only.

## Transfer maximums are settled before they are offered

[#686](https://github.com/synonymdev/bitkit-ios/pull/686) (porting
[bitkit-android#1179](https://github.com/synonymdev/bitkit-android/pull/1179) and
[#1180](https://github.com/synonymdev/bitkit-android/pull/1180)) settles both transfer maximums on an
amount the wallet can actually pay the LSP order fee for, rather than deriving one and hoping it
fits. Three behaviours it adds are covered by `transfer-spending-advanced-over-max.xml`:

- **The number pad and Continue are disabled while the maximum settles.** Settling costs one or two
  live fee quotes, so the advanced screen holds `NumberPad(isDisabled:)` until they return. Min,
  Default and Max stay tappable — that is the iOS shape; Android disables the amount buttons too.
- **An entered capacity above the settled maximum snaps down to it**, with
  `SpendingAdvancedExceededToast` naming the settled value. This is the snap
  `SpendingAmount.onMaxExceeded()` already performed, now on the advanced screen as well.
- **Tapping Max before the maximum settles is corrected once it does.** `updateInputCap()` brings the
  entered amount down when the settled maximum lands below it, so an early Max does not leave a
  capacity selected that no longer exists.

The journey sizes the transfer at **MAX** rather than 25% for this reason: settling only bites when
the client balance and the receiving capacity together crowd the funding budget, and at 25% the
settled maximum is simply the LSP's advertised maximum.

**Regtest is regression coverage here, not proof.** The staging/regtest service fee *falls* as the
client balance rises, where production's rises, which leaves a vulnerable window roughly 2 satoshis
wide against about 37 in production. Expect the settled maximum to equal the advertised one and the
two "comes down" steps to hold trivially. The unit tests in `BitkitTests/TransferViewModelTests.swift`
are the gate for the fix itself.

## Identifiers used
- Number pad keys: digits `N0`–`N9`, triple-zero `N000`, decimal `NDecimal`, delete `NRemove`.
- Send: screen `SendAmount`, field `SendNumberField`, available `AvailableAmount`,
  continue `ContinueAmount`; recipient `RecipientManual` / `RecipientInput` / `AddressContinue`;
  home Send button `Send`.
- Transfer→Spending: screen `SpendingAmount`, field `SpendingAmountNumberField`,
  available `SpendingAmountAvailable`, 25% `SpendingAmountQuarter`, max `SpendingAmountMax`,
  continue `SpendingAmountContinue`.
- Receiving capacity: screen `SpendingAdvanced`, field `SpendingAdvancedNumberField`,
  min/default/max `SpendingAdvancedMin`/`SpendingAdvancedDefault`/`SpendingAdvancedMax`,
  continue `SpendingAdvancedContinue`.
- External: funding `FundManual`; connection `NodeIdInput`/`HostInput`/`PortInput`/`ExternalContinue`;
  amount screen `ExternalAmount`, field `ExternalAmountNumberField`,
  available `ExternalAmountAvailable`, 25% `ExternalAmountQuarter`, max `ExternalAmountMax`,
  continue `ExternalAmountContinue`.
