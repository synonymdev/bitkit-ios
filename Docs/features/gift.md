# Gift

Claiming a Blocktank gift code through the Gift sheet (loading, used, used up, failed).

## What it does
- A scanned/pasted/deep-linked gift code decodes (in BitkitCore, not visible in this repo) to a `.gift(code, amount)` scanner result. `AppViewModel.swift:842` opens `SheetID.gift` with `GiftConfig(code:amount:)`.
- `GiftLoading` claims on open: waits for the node (`waitForNodeToRun`, 30 s) or 2 s for peers, then compares `wallet.totalInboundLightningSats` with the amount.
  - Enough inbound: creates an invoice with note `blocktank-gift-code:<code>` and calls `giftPay` (`claimWithLiquidity`).
  - Not enough: `giftOrder` for the node id, `CoreService.shared.blocktank.open`, inserts a received Lightning activity (message = code, fee 0), marks it seen, success haptic, shows `.receivedTx` sheet (`claimWithoutLiquidity`).
- Errors route by substring of the error text: `GIFT_CODE_ALREADY_USED` > `GiftUsed`; `GIFT_CODE_USED_UP` > `GiftUsedUp`; anything else > `GiftFailed` (struct in `GiftError.swift`).

## How a user reaches it
- No menu or button. Only by scanner data or an external URL. A test fixture URL shape is `bitkit://gift-code-1000` (`BitkitTests/PubkyAuthURLSchemeTests.swift:115`); the code/amount encoding is decoded in BitkitCore (could not verify).
- Deep link: `xcrun simctl openurl <udid> "bitkit://gift-..."`. `AppViewModel.swift:212` treats hosts with prefix `gift-` as not needing a running Lightning node for pending-link routing; claim itself still waits for the node.
- Scanner/paste: Home scan button (see `send.md`) with a gift payload; `.gift` is accepted as valid data at `AppViewModel.swift:1208`.
- Screen ids: `GiftLoading`, `GiftUsed`, `GiftUsedUp`, `GiftError` (the id for the failed screen; its struct is `GiftFailed`). Each result screen has an OK button (`common__ok`) without its own id (verified by grep).

## Code
- Sheet: `Bitkit/Views/Sheets/GiftSheet.swift` (`GiftRoute`: `.loading`, `.used`, `.usedUp`, `.failed`; `GiftConfig`; `GiftSheetItem`, size `.large`).
- Screens: `Bitkit/Views/Gift/GiftLoading.swift`, `GiftUsed.swift`, `GiftUsedUp.swift`, `GiftError.swift`.
- Wiring: `Bitkit/ViewModels/SheetViewModel.swift:11,217` (`giftSheetItem`), `Bitkit/MainNavView.swift:160-165`, `Bitkit/ViewModels/AppViewModel.swift:842`.
- Backend calls: `giftOrder`, `giftPay`, `CoreService.shared.blocktank.open` (BitkitCore / Blocktank).

## How to drive it
- Journeys: none. E2E: none (greps of `journeys/`, `bitkit-e2e-tests/test`, `docs` and README find no gift).
- A real claim needs a valid Blocktank gift code against the matching backend (regtest vs mainnet). Could not determine any fixture or `bitkit-docker` service that issues gift codes.
- Funds precondition is the inbound-capacity branch: with no channel the claim opens a new channel via Blocktank.

## What proves it
- Success (new channel path): `.receivedTx` sheet with the gift amount in sats, and a received Lightning activity whose message is the code.
- Success (liquidity path): `giftPay` returns; code does not navigate or show a sheet afterwards (no handling after `_ = try await giftPay`). Treat the payment arriving as the evidence (derived from code, unverified on device).
- Failures: `GiftUsed`, `GiftUsedUp`, `GiftError` visible.

## Not covered by tests
- No UI, journey or e2e test opens the Gift sheet or claims a code.
- Unit coverage only: `BitkitTests/PubkyAuthURLSchemeTests.swift` (a `bitkit://gift-code-1000` link routes without waiting for the node) and `BitkitTests/ShopPaymentRequestTests.swift:12` (`.gift` is not a supported Shop payment request).
- Untested: both claim branches, error-string mapping, node-wait timeout, scan-to-sheet decode.

## Gotchas
- Error routing matches on `String(describing: error)`; a changed backend error string lands on the generic failed screen.
- `GiftUsedUp` header uses `t("Out of Gifts")`, a literal rather than a localization key (`GiftUsedUp.swift:9`).
- In the liquidity path nothing closes the sheet or shows success after `giftPay` (`GiftLoading.swift:77`); the loading screen stays until the sheet is dismissed or the payment event closes it elsewhere (could not determine).
- Gift is not gated by `PaykitFeatureFlags`.
- A gift link scanned in the Shop embed scope (`.paymentRequests`) is not supported.
