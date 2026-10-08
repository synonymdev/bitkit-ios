# Receive

Receive sheet (onchain, lightning, unified/Auto, CJIT, hardware tab), invoice editing (amount, note, tags), and the "payment received" sheet. LNURL-withdraw is in `lnurl.md`; Payment Request routes inside the sheet are in `payment-requests.md`; the hardware tab is in `hardware-wallet.md`.

## What it does
- Shows a QR/address per tab: Savings (onchain, `lightning` param stripped), Auto (BIP21 with `lightning=`), Spending (bolt11 or CJIT invoice), Hardware (only when a hardware wallet exists). `ReceiveQr.swift` `qrConfig(for:)`.
- Auto is offered only when `wallet.bolt11` is non-empty and no CJIT invoice is shown (`canShowUnifiedReceive`) and becomes the default tab then (`applyDefaultTabIfNeeded`). If bolt11 empties while on Auto it falls back to Savings.
- Lightning invoice exists only with a ready channel and inbound liquidity: `ReceiveLiquidityDecision.canCreateLightningInvoice`. Otherwise `bolt11 = ""` and the Spending tab shows CJIT onboarding.
- Onchain address comes from the selected address type (`selectedAddressType` in UserDefaults) via `WalletViewModel.refreshReusableOnchainAddress`; a used address is replaced with a new one on refresh.
- Edit (`ReceiveEdit`): amount (number pad), note, tags (not for hardware/`onchainOnly`). Show QR regenerates the BIP21/bolt11 with `amount=`/`message=`. Sheet reopen clears amount, note, tags (`ReceiveSheet.onAppear`).
- Edit from Spending can route to CJIT when the amount exceeds inbound liquidity (`ReceiveLiquidityDecision.additionalLiquidityAction`: none / chooseAmount / createCjit / geoBlocked). Savings/Auto edits never route to CJIT. Rules in `Docs/receive-liquidity.md`.
- CJIT: amount screen (min from Blocktank, max from `blocktank.maxCjitAmountSats()`), confirmation (fees, notification toggle), learn-more, geo-block screen, then QR with `tab: .spending`. Wording switches to "additional" copy when a channel exists.
- Received sheet (`ReceivedTx`): onchain via LDK events `onchainTransactionReceived` and `onchainTransactionConfirmed`, lightning via `paymentReceived`, CJIT via `channelReady` with a CJIT order, hardware watcher via `hwWalletManager.receivedTxPublisher`.

## How a user reaches it
- Home tab bar: `Receive` (`Components/TabBar/TabBar.swift`) opens `.receive`. On the hardware wallet screen it opens the hardware tab. On the Spending wallet screen with no usable lightning receive and no pending transfer it opens `.cjitAmount` directly (`shouldOpenSpendingCjitEntry`).
- Also: `FundReceive` in `Views/Transfer/FundingOptions.swift` (opens `.cjitAmount`), the no-funds alert there (opens Savings tab), `Views/Contacts/ContactDetailView.swift` (`.requestOrPay`).
- Tabs: `Tab-savings`, `Tab-auto`, `Tab-spending`, hardware `Tab-<model name lowercased>`. Built from title text in `SegmentedControl.swift`, English only.
- On the sheet: `ReceiveScreen` (container), `QRCode` (QR; the Show QR button reuses the same id), `ShowDetails`, `ReceiveOnchainAddress`, `ReceiveLightningAddress`, `SpecifyInvoiceButton` (Edit, QR view only; the details view's Edit button has no id), `ReceiveCopyQR`, `ReceiveRequestPayment` (Paykit only).
- Edit: `ReceiveNumberPadTextField` (tap to focus the pad), `ReceiveNumberField`/`ReceiveNumberPad` (pad containers), `ReceiveNumberPadUnit`, `ReceiveNumberPadSubmit`, `ReceiveNote`, `TagsAdd`, `TagInputReceive`, `ReceiveTagsSubmit`, `Tag-<tag>`, `Tag-<tag>-delete`, `ShowQrReceive`.
- CJIT: `ReceiveCjitAmount`, `ReceiveCjitAmountNumberField`, `ReceiveCjitAmountContinue`, toasts `ReceiveCjitAmountExceededToast` and `ReceiveCjitNodeCapacityExceededToast`, `ReceiveCjitConfirm`, `ReceiveConfirmNotificationSwitch`, `ReceiveCjitLiquidity`, `ReceiveLiquidityNotificationSwitch`. The Spending-tab onboarding button ("Receive Spending") has no id.
- Received sheet: `ReceivedTransaction` (MoneyStack prefix: `-primary`/`-secondary`), `ReceivedTransactionButton`.

## Code
- Views: `Bitkit/Views/Wallets/Receive/` (`ReceiveSheet.swift` holds `ReceiveRoute`: `.qr`, `.edit`, `.tag`, `.cjitAmount`, `.cjitConfirm`, `.cjitLearnMore`, `.cjitGeoBlocked`, plus Paykit routes; `ReceiveQr`, `QrArea`, `ReceiveEdit`, `ReceiveTag`, `ReceiveCjit*`), `Bitkit/Components/CopyAddressCard.swift`, `Bitkit/Components/QR.swift`, `Bitkit/Components/SegmentedControl.swift`, `Bitkit/Views/Wallets/Sheets/ReceivedTx.swift`.
- Sheets: `SheetID.receive` (`ReceiveConfig`, shown in `MainNavView.swift`), `SheetID.receivedTx` (`ReceivedTxSheetDetails`).
- Logic: `Bitkit/Models/ReceiveLiquidityDecision.swift`, `Bitkit/ViewModels/WalletViewModel.swift` (`refreshBip21`, `canCreateReceiveLightningInvoice`, `paymentId`, `invoiceAmountSats`, `invoiceNote`), `Bitkit/ViewModels/BlocktankViewModel.swift` (`createCjit`, `refreshMinCjitSats`, `maxCjitAmountSats`), `Bitkit/Services/GeoService.swift`, `Bitkit/Utilities/Bip21Utils.swift`, `Bitkit/Managers/TagManager.swift`.
- Received sheet logic: `Bitkit/ViewModels/AppViewModel.swift` (`handleLdkNodeEvent`, `presentReceivedSheetForOnchainTransaction`, `shouldPresentConfirmedOnlyReceive`, `holdReceiveDuringRestore`).

## How to drive it
- Journeys (`journeys/onchain-receive/`): `confirmed-only-received-sheet.xml` ("confirmed-only onchain receive shows the received sheet"), `mempool-then-confirmed-single-sheet.xml` ("mempool-first onchain receive shows one sheet after confirmation"), `restore-recent-receive-stays-silent.xml` ("recent receive stays silent after a seed restore", needs a throwaway simulator). Preconditions: `E2E_BUILD` app on regtest, `bitkit-docker` stack, `lsp` helper from `../bitkit-android/lsp` (deposit/mine). Confirmed-only journey needs deposit and mine in one command.
- `journeys/cjit-notifications/*.xml` and `journeys/notification-permission/receive-cjit-*.xml` cover CJIT notifications and the toggles on the CJIT screens; see `notifications.md`.
- `journeys/amount-limits/README.md` mentions Receiving capacity, which is a transfer screen, not this one.
- e2e `bitkit-e2e-tests/test/specs/receive.e2e.ts`: `@receive_1`, describe tags `@receive @ios_nightly`. Fresh app, no funds.
- e2e `bitkit-e2e-tests/test/specs/lightning.e2e.ts`: `@lightning_1`, `@lightning @ios_gate`. Local docker LND (`BACKEND=local`), receives 10 000 and 111 sats over LN, edited invoice with note and tag, restore, channel close.
- e2e `bitkit-e2e-tests/test/specs/multiaddress.e2e.ts`: `@multi_address_1` (`@ios_nightly`), `_3` and `_4` (`@ios_gate`), `_2` (`@multi_address_staging`). Receives to each address type via `switchAndFundEachAddressType` (helper in `test/helpers/actions.ts`).
- e2e `bitkit-e2e-tests/test/specs/numberpad.e2e.ts`: `@numberpad_1` and `@numberpad_3` use Receive edit (`@numberpad @ios_nightly`). Funds 500 000 000 sats first.
- e2e `bitkit-e2e-tests/test/specs/onchain.e2e.ts`: `@onchain_1`, `@onchain_2` (`@ios_nightly`) receive and tag two addresses.
- e2e `bitkit-e2e-tests/test/specs/receive-ln-payments.e2e.ts`: utility, no tag, attaches to an installed app, pays N invoices (`PAYMENT_COUNT`, `PAYMENT_AMOUNT`). Not a gate test.
- e2e `bitkit-e2e-tests/test/specs/mainnet/cjit.e2e.ts`: `@cjit_mainnet`/`@cjit_1`, mainnet, optional `CJIT_SEED`, `CJIT_MIN_EXPECTED_SATS`. See Gotchas.
- Unit tests (`BitkitTests/`): `ReceiveLiquidityDecisionTests`, `ReceiveEditTests`, `ReceiveSheetSessionTests`, `TabBarReceiveTests`, `WalletViewModelReceiveTests`, `BlocktankViewModelCjitTests`, `Bip21UtilsTests`, `ConfirmedOnlyReceiveGuardTests`, `RestoreActivitySeenSuppressionTests`, `MarkAllUnseenActivitiesCutoffTests`, `AddressType*Tests`.

## What proves it
- Address: `getAddressFromQRCode` reads the `QRCode` accessibility value; regtest default must start `bcrt1` (`receive.e2e.ts`); `multiaddress.e2e.ts` checks the prefix per address type.
- After edit and Show QR, reopening Edit shows `123`, the note and the tag; after closing and reopening the sheet they are gone (`@receive_1`).
- Received: `ReceivedTransaction` visible with the amount, tapped away with `ReceivedTransactionButton`; balance (`TotalBalance-primary`) and `ActivityShort-0` update (`lightning.e2e.ts`, `onchain.e2e.ts`).
- CJIT screens: `ReceiveCjitConfirm` then `QRCode` shown (only the mainnet spec, see Gotchas).
- Journeys assert log lines `Onchain transaction received/confirmed: txid=` and `Skipping received sheet` in `logs/bitkit_*.log` in the app group container.

## Not covered by tests
- Regtest CJIT flow on iOS: no running e2e or journey covers `ReceiveCjitAmount`, `ReceiveCjitConfirm`, `ReceiveCjitLearnMore`, geo-block screen, or the `ReceiveCjitAmountExceededToast`/`ReceiveCjitNodeCapacityExceededToast` toasts. Unit tests cover only the decision logic and error normalization.
- Additional CJIT from a Spending edit (`createCjit` branch) and replacing a stale CJIT QR route end to end: unit-tested only (`ReceiveEditTests`).
- Auto tab default and fallback to Savings when the edited amount exceeds inbound: no UI test (logic is in `ReceiveLiquidityDecisionTests`).
- Share button, Copy tooltip and clipboard content: not asserted.
- Hardware tab (address load, verify address, passphrase): see `hardware-wallet.md`.
- Mempool-then-confirmed and confirmed-only sheets are journey-only (manual, not CI). The Android-only background notification journey is not ported (`journeys/README.md`, "Not ported").
- Lightning received sheet for a CJIT `channelReady`: no test could be found.
- Offline overlay on the Receive sheet (`offlineSheetOverlay`): could not determine any test.

## Gotchas
- `Docs/` is the git-tracked directory name (capital D) although `docs/` also resolves on a case-insensitive filesystem.
- `QRCode` is the id of both the QR image and the "Show QR" button; the e2e helper `getUriFromQRCode` reads the QR image while details are hidden.
- `SpecifyInvoiceButton` exists only in the QR view. `tap('QRCode')` after `ShowDetails` in `@receive_1` switches back to the QR view first.
- `mainnet/cjit.e2e.ts` uses `ReceiveAmountMin` and `ContinueAmount` after `Tab-spending` then `ShowDetails`. None of those ids/steps exist in the iOS CJIT flow (iOS shows an id-less onboarding button, `ReceiveCjitAmountContinue`, no `ReceiveAmountMin`). The spec looks Android-shaped; no workflow in the e2e repo references it. Unverified on iOS.
- Confirmed-only receives are shown only if the block time is within 1 hour of the device clock, no migration runs, and the block is above `restoreSyncedBlockHeight`. Right after a restore all onchain received sheets are held until the first onchain sync (`journeys/onchain-receive/README.md`).
- `SheetViewModel.showSheet` skips `.receivedTx` while the Send sheet is active.
- Received sheet opens 500 ms after the event so the activity is written first; dedupe by txid in-session (`receivedSheetInFlightTxids`) and by persisted seen state.
- Wallet sync runs every 10 s on regtest; allow 30 s for the sheet.
- iOS posts no local notification for an onchain receive; notification extension handles only Blocktank pushes.
- A zero-amount lightning invoice is allowed whenever inbound > 0 (`Docs/receive-liquidity.md`).
- `getReceiveAddress('lightning')` in e2e fails until a bolt11 exists; specs retry after pull-to-refresh.
