# Amount-limit journeys

These journeys exercise the "block number pad input exceeding the max/available amount" behaviour.
The same `AmountInputViewModel` cap + `maxExceededCount` effect path backs the amount-entry
screens. Two over-max journeys remain: Send and External node. The Transfer→Spending, Receiving-capacity and
hardware Transfer To Spending journeys are retired because Blocktank channel purchases were removed
(synonymdev/bitkit-ios#1097); their screens still back the same view model but no button navigates
to them.

`custom-fee-wallet-switch.xml` covers adjacent send preparation: a custom fee switches Spending to
Savings, with manual or automatic coin selection after returning through the fee picker. It requires
a unified invoice and balances on both rails, but never submits a payment. This two-stage return is
iOS-only; Android applies the fee and returns directly to confirmation.

### Pending coin preparation and Tags (manual)

Suspending wallet UTXO loading is not a journey capability. With a controlled wallet fixture,
enable manual coin selection, open a unified invoice on Spending, switch to Savings and hold the
UTXO read. Open Tags before releasing the read; coin selection must not open over Tags. Return
to confirmation and verify preparation resumes, the swipe stays unavailable while it runs, and
the manual coin picker opens. Repeat with automatic selection and verify the selected coins
are prepared on return. Closing or replacing the send while Tags is open must discard the old
preparation. Do not submit a payment.

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
2. **The External-node flow needs the node running** so the on-chain maximum can be computed;
   wait for the available amount to populate before typing.
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
  (`SendAmountExceededToast`, `ExternalAmountExceededToast`) immediately after the over-max keypress.
- Prefer `snapshot-ui` and tap elements by identifier (`N9`, `NRemove`) over screen coordinates.

## Verified behaviour

Send was walked on an iPhone 17 simulator against the stag0 regtest backend. **Send caps by rejecting
the keypress, so assert "does not exceed the stated maximum" — never a specific value:**

| Screen | Cap | Nine taps on `N9` | After one `NRemove` |
| --- | --- | --- | --- |
| Send | 297 393 | **99 999** — the largest all-9s value still under the cap | 9 999 |

On Send, Continue stays enabled throughout: the cap is applied to the input rather than leaving it in
an invalid state. The exceeded toasts fire on the first rejected keypress and are gone well before a
snapshot round-trip returns — race a `wait-for-ui` on the toast identifier against the taps.

The transfer-maximum settling from [#686](https://github.com/synonymdev/bitkit-ios/pull/686) is no
longer reachable from the UI; the unit tests in `BitkitTests/TransferViewModelTests.swift` remain its
gate.

## Identifiers used
- Number pad keys: digits `N0`–`N9`, triple-zero `N000`, decimal `NDecimal`, delete `NRemove`.
- Send: screen `SendAmount`, field `SendNumberField`, available `AvailableAmount`,
  continue `ContinueAmount`; recipient `RecipientManual` / `RecipientInput` / `AddressContinue`;
  home Send button `Send`.
- External: Lightning Connections add button (navigation bar `+`, `NavigationAction`; the bottom
  "Get Started"/"Add Connection" button has no identifier, Android `add_connection_button`) opens
  Funding Advanced, then `FundManual`; connection `NodeIdInput`/`HostInput`/`PortInput`/`ExternalContinue`;
  amount screen `ExternalAmount`, field `ExternalAmountNumberField`,
  available `ExternalAmountAvailable`, 25% `ExternalAmountQuarter`, max `ExternalAmountMax`,
  continue `ExternalAmountContinue`.

## Retired journeys

`transfer-spending-over-max.xml` and `transfer-spending-advanced-over-max.xml` were retired because
Blocktank channel purchases were removed (synonymdev/bitkit-ios#1097), and so was
`../hardware-wallet/transfer-to-spending-over-max.xml`. Their routes started at the Savings wallet's
"Transfer To Spending" button or the hardware wallet's, which now open the "New Channels Unavailable"
sheet. The amount screens' identifiers (`SpendingAmount*`, `SpendingAdvanced*`,
`HardwareTransferAmount*`) are no longer reachable from the UI.
