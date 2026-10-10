# Send

Sending bitcoin: scan, paste or type a recipient (onchain, BOLT11, BIP21/unified), amount, fee and UTXO choice, review, PIN, swipe to pay, quickpay, success/failure/pending. LNURL is in `lnurl.md`; contact sends in `contacts.md` and `payment-requests.md`; hardware signing in `hardware-wallet.md`; boost is in `activity.md`.

## What it does
- Scanner (`ScannerManager.handleScan/handlePaste/handleImageSelection/handleManualEntry`) and `AppViewModel.handleScannedData` classify the input: strips `lightning:` schemes, rejects duplicated BIP21 (`InvalidAddressToast`), checks network mismatch, then decodes via `decode(invoice:)` (BitkitCore, not read).
- Result sets `app.scannedOnchainInvoice` / `scannedLightningInvoice` / `lnurlPayData` and `selectedWalletToPayFrom`. `PaymentNavigationHelper` then picks the sheet route: amountless LN or onchain -> `SendRoute.amount`; LN with amount -> `.confirm`; quickpay if eligible -> `.quickpay`.
- Pre-checks with the node running: pure LN with no channel -> `InsufficientSpendingToast`, no sheet; onchain balance below invoice -> `InsufficientSavingsToast`; expired invoice -> `ExpiredLightningToast`; wrong network -> `InvalidAddressToast`. Matrix of expected outcomes: `Docs/SCAN_INVOICE_TEST_MATRIX.md` (onchain, LN, expired, unified zero/small/large/expired-LN, by balance and channel state).
- Unified (BIP21 with `lightning=`): prefers lightning when valid, not expired and affordable; otherwise falls back to onchain silently. If channels exist but none are usable, `SendSheet` shows `SendSyncScreen` and falls back after 20 s (`syncTimeoutSeconds`). Node not running: validation is deferred until it runs (`SendSheet.validatePaymentAfterSync`).
- Amount (`SendAmountView`): funding source button (`AssetButton-savings|spending|switch|trezor`); available = LN max minus estimated routing fee (hard-coded 2 sat buffer) or max sendable onchain; input capped at available with `SendAmountExceededToast`; tapping `AvailableAmount` sets max (no Max button); LN invoice with amount skips this screen.
- Onchain: manual coin selection (`settings.coinSelectionMethod == .manual`) opens `.utxoSelection`; otherwise `wallet.setUtxoSelection(algorithm)` runs on Continue. Fee/speed via `.feeRate` and `.feeCustom`. Change below dust is added to the fee (`isMaxAmountSend`, `DustChangeHelper`).
- Review (`SendConfirmationView`): swipe `GRAB`; warnings (alerts) for amount > 50% of balance, > $100 when `warnWhenSendingOver100`, fee > $10, fee > 50% of amount; PIN or biometrics when `requirePinForPayments && pinEnabled`; tag; edit amount (amountless LN or onchain only) or address by tapping amount or `ReviewUri`.
- Result: `SendSuccess` (`Details` opens the activity, `Close`), `SendPendingScreen` for unresolved LN payments, `SendFailure` (`Retry`, `Support`; retry may reset routing caches).
- Quickpay: LN invoice with amount under the Settings threshold and daily cap pays without review (`QuickPayPaymentCoordinator`, `QuickPaySpendStore`, `QuickPayLimits`). Intro sheet `SheetID.quickpay` is a timed sheet.

## How a user reaches it
- Tab bar `Send` (opens `.send`, route `.options`), tab bar `Scan` (`ScanButton`, opens `.scanner` sheet), `ScannerScreen` via `Route.scanner` from Contacts, manual node setup, Electrum settings (contexts `addContact`, `electrum`, `main`).
- Options screen (`SendOptionsView`): live camera scanner (permission via `CameraManager`), `RecipientContact`, `RecipientInvoice` (paste), `RecipientManual`.
- Manual: `RecipientInput` (TextEditor), `AddressContinue` (enabled only when `isManualEntryInputValid`, validated with debounce, toasts as above).
- E2E builds: scanner `ScanPrompt` -> `QRDialog`, `QRInput`, `DialogConfirm`, `DialogCancel`.
- Amount: `SendAmount`, `SendNumberField`, `AvailableAmount`, `SendNumberPadUnit`, `ContinueAmount`, `N0`-`N9`, `N000`, `NDecimal`, `NRemove`.
- Review: `SendConfirm` (or `PaymentRequestConfirm`), `ReviewAmount(-primary|-secondary)`, `ReviewUri`, `SendConfirmAssetButton`, `SendConfirmToggleDetails`, `SendConfirmRetryFeeRate`, `TagsAddSend`, `SendTagsSubmit`, `GRAB`. Fee and UTXO rows and the PIN keys (`N0`-`N9`, `WrongPIN`) are reached through buttons without ids.
- Result: `SendSuccess`, `Details`, `Close`, `SendFailure`, `SendFailureMessage`, `Retry`, `Support`.
- Quickpay settings toggle `QuickpayToggle`, `QuickpaySettings`; intro `QuickpayIntro`.

## Code
- Sheet: `SheetID.send`, `SendConfig`, `SendSheetItem`, `SendRoute` (`.options`, `.contact`, `.manual`, `.amount`, `.utxoSelection`, `.confirm`, `.hardwareSign`, `.feeRate`, `.feeCustom`, `.tag`, `.quickpay`, `.pin`, `.pending`, `.success`, `.failure`, `.lnurl*`) in `Bitkit/Views/Wallets/Send/SendSheet.swift`; presented in `Bitkit/MainNavView.swift`. Scanner: `SheetID.scanner` (`Bitkit/Views/Scanner/ScannerSheet.swift`), `Bitkit/Views/Scanner/ScannerScreen.swift`, `Bitkit/Views/Scanner/ManualScanPrompt.swift`, `Bitkit/Components/Scanner.swift`, `Bitkit/Managers/ScannerManager.swift`, `Bitkit/Managers/CameraManager.swift`.
- Screens: `Bitkit/Views/Wallets/Send/` (`SendOptionsView`, `SendEnterManuallyView`, `SendAmountView`, `SendConfirmationView`, `SendUtxoSelectionView`, `SendFeeRate`, `SendFeeCustom`, `SendQuickpay`, `SendPinScreen`, `SendPendingScreen`, `SendSuccess`, `SendFailure`, `SendSyncScreen`, `SendTagScreen`, `SendContactSelectView`, `HwSendSignView`).
- Logic: `Bitkit/ViewModels/AppViewModel.swift` (`handleScannedData`, `validateManualEntryInput`, `resetSendState`), `Bitkit/ViewModels/WalletViewModel.swift` (`sendAmountSats`, `setFeeRate`, `loadFeeRateWithRetry`, `setUtxoSelection`, `loadAvailableUtxos`, `maxSendLightningSats`), `Bitkit/Utilities/PaymentNavigationHelper.swift`, `Bitkit/Utilities/QuickPayPaymentCoordinator.swift`, `Bitkit/Utilities/NetworkValidationHelper.swift`, `Bitkit/Utilities/Bip21Utils.swift`, `Bitkit/Services/LightningService.swift`, `Bitkit/Services/CoreService.swift`, `Bitkit/Managers/FeeEstimatesManager.swift`, `Bitkit/Views/Sheets/QuickpaySheet.swift`, `Bitkit/Managers/TimedSheets/QuickpayTimedSheet.swift`.

## How to drive it
- Journey `journeys/amount-limits/send-amount-over-balance.xml` ("send amount over balance is blocked"): fund ~100 000 sats with the `lsp` helper (`../bitkit-android/lsp POST /regtest/chain/deposit`, then `.../mine`), `E2E_BUILD` app. See `journeys/amount-limits/README.md` (cap can be below the visible balance; Continue stays enabled; toast fades fast).
- Journey `journeys/lnurl/pay-no-spending-balance.xml`: paste path; see `lnurl.md`. Other journeys that send: `hardware-wallet/send-onchain.xml`, `payment-requests/*.xml`, `contacts/contact-payment-sharing.xml`.
- e2e `bitkit-e2e-tests/test/specs/send.e2e.ts` (describe `@send`): `@send_1 @ios_gate` manual-entry validation (toasts, unified invoices, over-balance), `@send_2 @ios_gate` onchain, LN, unified, quickpay, large amount skips quickpay; `@send_3 @ios_gate` msat-precision invoices. `_2`/`_3` need `BACKEND=local` with docker LND (`setupLND`, `connectToLND`, `openLNDAndSync`).
- e2e `bitkit-e2e-tests/test/specs/onchain.e2e.ts`: `@onchain_1`, `@onchain_2` (`@ios_nightly`), `@onchain_3` (tag `@onchain` only, dust output and two warning dialogs).
- e2e `bitkit-e2e-tests/test/specs/lightning.e2e.ts`: `@lightning_1 @ios_gate`, sends to amountless and fixed LN invoices, edits amount on review, send tag.
- e2e `bitkit-e2e-tests/test/specs/boost.e2e.ts`: `@boost_1` (CPFP) and `@boost_2` (RBF), `@boost @ios_gate`. Boost opens from the activity detail (`BoostButton` in `Views/Wallets/Activity/ActivityItemView.swift`, `SheetID.boost`), not from the send flow; see `activity.md`.
- e2e `bitkit-e2e-tests/test/specs/multiaddress.e2e.ts`: `@multi_address_1`, `_3` (send 30 000 then RBF), `_4`. `bitkit-e2e-tests/test/specs/numberpad.e2e.ts`: `@numberpad_2`, `@numberpad_4` (Send amount pad, modern and classic). `bitkit-e2e-tests/test/specs/security.e2e.ts` `@security_1` sends with PIN.
- e2e `bitkit-e2e-tests/test/specs/mainnet/ln.e2e.ts` (`@strike_1`, `@wos_1`) and `mainnet/probe.e2e.ts` (`@probe_mainnet_1`): see `lnurl.md`. Background reading: `bitkit-e2e-tests/docs/lightning-primer-for-qa.md` (channel monitor/`update_id`, desync recovery; no send steps).
- Unit tests: `SendConfirmationViewTests`, `SendConfirmationSwipeTests`, `PaymentNavigationHelperTests`, `QuickPay*Tests`, `UtxoSelectionTests`, `DustChangeHelperTests`, `WalletViewModelSendTests`, `NetworkValidationHelperTests`, `NumberPadTests`, `BroadcastConnectivityTests`, `LnurlPayConfirmTests`, `LightningAmountConversionTests`.

## What proves it
- `SendSuccess` visible, then `Close`; `TotalBalance-primary` and `ActivitySavings`/`ActivitySpending` change; `ActivityShort-0` shows `-`, `Sent` and the amount.
- Validation: toast ids `InvalidAddressToast`, `InsufficientSavingsToast`, `InsufficientSpendingToast`, `ExpiredLightningToast`, `SendAmountExceededToast`; `AddressContinue` disabled.
- Review: `ReviewAmount-primary` shows the invoice or edited amount; `AssetButton-*` shows which wallet pays.
- Warnings: alert text "over 50%" / "over $100" (`handleOver50PercentAlert`, `handleOver100Alert`).
- Quickpay: `SendSuccess` appears with no `GRAB` swipe; with an amount above the cap `ReviewAmount` appears instead.
- PIN: text "Enter PIN Code" after the swipe, then `SendSuccess`.

## Not covered by tests
- Manual UTXO selection (`SendUtxoSelectionView`), fee speed picker (`SendFeeRate`), custom fee (`SendFeeCustom`): no e2e or journey drives them (only `boost.e2e.ts` uses a different fee UI). `@settings_03` only changes the default speed in Settings.
- `SendPendingScreen`, `SendFailure` retry with routing-cache reset, `SendSyncScreen` fallback after 20 s, failed fee-rate load with `SendConfirmRetryFeeRate`: no e2e or journey; unit tests cover failure classification (`SendConfirmationViewTests`), swipe state (`SendConfirmationSwipeTests`), fee-rate retry (`WalletViewModelSendTests`) and quickpay pending states (`QuickPayPaymentCoordinatorTests`).
- Camera scanning, photo-library QR import (`handleImageSelection`) and its error toasts, clipboard-empty toast: not driven.
- Biometric authentication for payments, biometric error alert: not covered (PIN path only).
- `fee > $10` and `fee > 50%` warnings: not covered (only 50% balance and $100 are).
- Hardware wallet send: see `hardware-wallet.md`. Contact send: see `contacts.md`.
- Pasting via `RecipientInvoice` needs the iOS paste permission prompt; no test handles it (journeys describe it as a manual step).
- `ProbingToolScreen` (Settings) is a separate invoice-probing tool not tested here; could not determine its coverage.

## Gotchas
- E2E `enterAddress` taps `Send`, `RecipientManual`, types, taps `AddressContinue`; it dismisses the camera dialog only on Android. `enterAddressViaScanPrompt` uses `Scan` then `ScanPrompt` (E2E builds only).
- iOS has no Max button; tap `AvailableAmount`. iOS max for lightning is lower than Android by the routing fee estimate (`send.e2e.ts` expects `5 998` where Android shows `6 000`).
- iOS runs coin selection on Continue; sending the exact onchain max can fail with a "Coin selection failed" toast (`send.e2e.ts` backs off with `NRemove`).
- `@send_1` is tagged `@ios_gate` in the spec, but `bitkit-e2e-tests/AGENTS.md` lists it under `@ios_nightly`. Trust the spec until the table is fixed (unresolved).
- `@send_2`, `@send_3`, `@lightning_1` require local docker LND; they cannot run against `BACKEND=regtest`. `BACKEND` must match how the app was built.
- Amount caps: Send rejects the keypress that would exceed the cap (largest all-9s value under it); transfer screens snap to the max (`journeys/amount-limits/README.md`).
- LN payments display ceil sats for msat invoices; payment of msat invoices is exact (`@send_3`).
- Send sheet blocks `.receivedTx` while open (`SheetViewModel.showSheet`).
- Quickpay needs `QuickpayToggle` on; the intro timed sheet must be dismissed first (`dismissQuickPayIntro`). Amount must be > 0 and within threshold and daily cap; otherwise the normal confirm screen.
- Regtest LN routing noise: stale RGS can give transient "route not found" (`lightning-primer-for-qa.md`).
- `SCAN_INVOICE_TEST_MATRIX.md` BOLT11 samples expire; generate fresh invoices for non-expiry cases.
- `LnurlPayConfirm` shows a hard-coded fee label "Instant (±$0.02)" (TODO in code).
