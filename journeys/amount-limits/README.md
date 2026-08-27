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
   - Fund and mine via the regtest backend:
     `./lsp POST /regtest/chain/deposit '{"address":"<addr>","amountSat":100000}'`
     then `./lsp POST /regtest/chain/mine '{"count":3}'`, and wait for the balance to sync.
2. **Transfer/Spending and Receiving-capacity flows need the node connected to the LSP** so a real
   max can be quoted. On the Spending amount screen the max starts at `0` behind a spinner — wait
   for it to populate before typing.
3. **The external-node flow needs a reachable Lightning peer.** The staging LSP node works
   (`./lsp GET /info` for its id/host/port).

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

Both walked on an iPhone 17 simulator. **The two screens cap differently, so assert "does not exceed
the stated maximum" — never a specific value:**

| Screen | Available | Nine taps on `N9` | After one `NRemove` |
| --- | --- | --- | --- |
| Send | 297 393 | **99 999** — the largest all-9s value still under the cap | 9 999 |
| Transfer → Spending | 296 522 | **296 522** — clamped to the max exactly | 29 652 |

Continue stays enabled throughout on both: the cap is applied to the input rather than leaving it in
an invalid state. The `SpendingAmountExceededToast` fires on the first rejected keypress and is gone
well before a snapshot round-trip returns — race a `wait-for-ui` on its identifier against the taps.

The Transfer → Spending max populates from the on-chain balance and cached Blocktank info, so the
screen is reachable and cappable even with the regtest backend down. That is *not* a substitute for
a real LSP quote: without one the numbers are not the ones a real transfer would use.

## Pending: PR #686

[#686](https://github.com/synonymdev/bitkit-ios/pull/686) settles both transfer maximums and adds to
`SpendingAdvancedView` the snap that `SpendingAmount.onMaxExceeded()` already performs — an entered
capacity above the settled maximum comes down to it instead of the keypress being rejected. The
existing assertion ("does not exceed the maximum receiving capacity") holds either way, but three
behaviours it introduces are not covered yet and should be added to
`transfer-spending-advanced-over-max.xml` when it lands:

- the number pad is disabled while the maximum settles
- an entered capacity above the settled maximum snaps down to it, with the toast showing the settled value
- tapping Max before the maximum settles brings the entered amount down once it does

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
