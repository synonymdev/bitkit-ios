# Transfer

Moving funds between Savings (on-chain) and Spending (Lightning): Blocktank LSP channel orders, spending back to savings (channel close or Boltz swap), force close, external-node and LNURL channels, transfer tracking. Hardware-wallet funding is in `hardware-wallet.md`.

## What it does
- Savings to Spending: the user enters a spending amount, the app estimates a Blocktank order fee, the confirm swipe creates the order (`BlocktankViewModel.createOrder`), pays its on-chain address from savings (`TransferViewModel.payOrder`), then polls the order every 15 s (`watchOrder`). `lightningSetupStep` 0..3 drives `SettingUpView`; at 3 (order has a channel) it shows success.
- Advanced mode lets the user choose the LSP-side (receiving) capacity; `SpendingConfirmDefault` returns to the default split.
- Amount screens cap the number pad at a settled maximum and show a warning toast on the first rejected keypress (`AmountInputViewModel.maxAmountOverride`, `maxExceededCount`).
- Spending to Savings (`SavingsProgressView`): mode `.swap` (Boltz reverse swap, channels stay open) only when `BoltzService.isSwapEnabled` and a priced quote exists; otherwise `.close` (cooperative close of the selected channels). `BoltzService.isSwapEnabled` needs `Env.isSwapSupported` (mainnet only) and the dev toggle `savingsSwapEnabled`.
- Coop close failure: `startCoopCloseRetries` retries every 60 s for 30 min, then opens `ForceTransferSheet` if a non-trusted channel remains. Trusted-peer (LSP) channels cannot be force closed; a toast `lightning__close_error` shows instead (`LightningService.separateTrustedChannels`).
- Manual channel: node id, host, port, then amount, then swipe; `TransferViewModel.openManualChannel` opens the channel and records a `toSpending` transfer with the channel id. LNURL channel (scan) shows node/host/port and a Connect button.
- Transfer tracking: `TransferService`/`TransferStorage` store `Transfer` records (`TransferType`: toSpending, toSavings, manualSetup, forceClose, coopClose). `syncTransferStates` settles a to-spending transfer when its channel is usable, an expired order, or a to-savings transfer when the channel balance is gone (force close waits for the sweep).
- `TransferTrackingManager` wraps `TransferService` for views (`loadActiveTransfers`, `createTransfer`, `markSettled`, `syncTransferStates`).

## How a user reaches it
- Home: tap `ActivitySavings` (`Bitkit/Views/Home/HomeWalletView.swift`), screen `SavingsWalletScreen`, button `TransferToSpending`. First run goes to `SpendingIntro` (button `SpendingIntro-button`, flag `hasSeenTransferToSpendingIntro`), afterwards straight to `SpendingAmount`.
- `ActivitySpending` opens `SpendingWalletScreen`: `TransferFromSavings` shows only when spending balance is 0, no Lightning activity, savings > 0, not geo-blocked. With a channel, `TransferToSavings` shows (needs `wallet.channels` non-empty) and goes to `SavingsIntro` (`SavingsIntro-button`) then `SavingsAvailability` (`AvailabilityContinue`) then `SavingsConfirm`.
- Home suggestion card `Suggestion-lightning` (`Bitkit/Components/Widgets/Suggestions.swift`): `TransferIntro` (`TransferIntro-button`) then `FundingOptions`.
- Settings > Advanced > Channels (`LightningConnectionsView`): plus icon `NavigationAction` or the bottom button opens `FundingOptions`.
- `FundingOptions` buttons: `FundTransfer` (alert if on-chain is 0; disabled when geo-blocked), `FundReceive` (opens the Receive sheet at CJIT amount, see `receive.md`), `FundManual`.
- `FundAdvancedOptions` (from `ReceiveCjitGeoBlocked`): `FundLnUrl` (opens scanner), `FundManual`.
- Spending flow: `SpendingAmount` (`SpendingAmountNumberField`, `SpendingAmountAvailable`, `SpendingAmountQuarter`, `SpendingAmountMax`, `SpendingAmountContinue`), then `SpendingConfirm` (`SpendingConfirmMore`, `SpendingConfirmAdvanced` or `SpendingConfirmDefault`, `SpendingConfirmNotificationSwitch`, `SpendingConfirmChannel` in advanced mode, swipe handle `GRAB`), then `SettingUpView` (`LightningSettingUp`, then `TransferSuccess`, `TransferSuccess-button`).
- `SpendingConfirmMore` opens `TransferLearnMoreView` (`LiquidityContinue`). `SpendingConfirmAdvanced` opens `SpendingAdvanced` (`SpendingAdvancedNumberField`, `SpendingAdvancedMin`/`Default`/`Max`, `SpendingAdvancedContinue`); Continue dismisses back to confirm.
- Savings confirm: `GRAB` swipe; buttons "Advanced"/"Transfer all" (only with more than one ready channel) and "close instead" (only with a swap quote) have no identifier. Success: `TransferSuccess` and `TransferSuccess-button` (state `.success`).
- Force close: sheet `ForceTransferSheet` (`ForceTransferSheet`, `ForceTransferSheetCancel`, `ForceTransferSheetContinue`; derived from `SheetIntro` testID). Also opened from `CloseConnectionConfirmation` (Settings > Advanced > Channels > channel > `CloseConnection` > `CloseConnectionButton`), see `settings.md` (or `settings-advanced.md` if split).
- External: `FundManual` > `NodeIdInput`, `HostInput`, `PortInput`, `ExternalContinue` > `ExternalAmount` (`ExternalAmountNumberField`, `ExternalAmountAvailable`, `ExternalAmountQuarter`, `ExternalAmountMax`, `ExternalAmountContinue`) > confirm (`GRAB`, no screen id) > `ExternalSuccess`, `ExternalSuccess-button`. A scanned node URI jumps to `fundManual(nodeUri:)` (`AppViewModel.handleNodeUri`).
- LNURL channel: scanned lnurl-channel opens `LnurlChannel` (`ConnectButton`), then `fundManualSuccess`.
- Dev screens: Settings > Advanced > Dev Settings (`DevSettings`; shown in Debug builds or via `showDevSettings`) rows Orders (`ChannelOrders`), Swaps (`SwapsListView`, `SwapDetailView`), `SavingsSwapToggle`.
- Dynamic ids: `OnboardingView` builds `<testID>-button`; `SheetIntro` builds `<testID>Cancel` / `<testID>Continue`; number pad keys `N0`..`N9`, `N000`, `NRemove`.

## Code
- Views `Bitkit/Views/Transfer/`: `TransferIntroView`, `FundingOptions`, `SpendingIntroView`, `SpendingAmount`, `SpendingConfirm`, `SpendingAdvancedView`, `TransferLearnMoreView`, `SettingUpView`, `SavingsIntroView`, `SavingsAvailabilityView`, `SavingsConfirmView`, `SavingsAdvancedView`, `SavingsProgressView`, `FundAdvancedOptions`, `FundManualSetupView`, `FundManualAmountView`, `FundManualConfirmView`, `FundManualSuccessView`, `LnurlChannel`, `TransferFundingBudget`. `FundReceiveView.swift` only renders `Text("FundReceiveView")` and no route uses it. Sheet: `Bitkit/Views/Sheets/ForceTransferSheet.swift`. Banner: `Bitkit/Components/IncomingTransfer.swift`.
- Routes (`Bitkit/ViewModels/NavigationViewModel.swift`, switch in `Bitkit/MainNavView.swift` lines 505-528): `transferIntro`, `fundingOptions`, `spendingIntro`, `spendingAmount`, `spendingConfirm`, `spendingAdvanced`, `transferLearnMore`, `settingUp`, `fundingAdvanced`, `fundManual`, `fundManualAmount`, `fundManualConfirm`, `fundManualSuccess`, `lnurlChannel`, `savingsIntro`, `savingsAvailability`, `savingsConfirm`, `savingsAdvanced`, `savingsProgress`. Sheet case `SheetID.forceTransfer`.
- Logic: `Bitkit/ViewModels/TransferViewModel.swift` (limits, order reuse, `payOrder`, `watchOrder`, `openManualChannel`, `closeChannels`, `startCoopCloseRetries`, `forceCloseChannel`, `loadSavingsSwapQuote`, `executeSavingsSwap`), `Bitkit/ViewModels/BlocktankViewModel.swift`.
- Tracking: `Bitkit/Services/TransferService.swift`, `TransferStorage.swift`, `Bitkit/Managers/TransferTrackingManager.swift`, `Bitkit/Models/Transfer.swift`, `TransferType.swift`. `AppScene.swift` injects `TransferTrackingManager` with `.environmentObject`; a grep of `Bitkit/` found no view that declares it.
- Swap: `Bitkit/Services/BoltzService.swift`. Order restart: `BlocktankViewModel.startWatchingPendingOrders` (called from `AppScene.swift`).

## How to drive it
- Journeys: `journeys/transfer/spending-confirm-amount-change.xml` ("spending confirm amount change"); `journeys/amount-limits/transfer-spending-over-max.xml` ("transfer to spending amount over max is blocked"), `transfer-spending-advanced-over-max.xml` ("receiving capacity amount over max is blocked"), `external-amount-over-max.xml` ("external node amount over max is blocked"); `journeys/notification-permission/transfer-spending-confirm-notification-toggle.xml` (see `notifications.md`). Hardware variants: see `hardware-wallet.md`.
- Journey setup: build with `E2E_BUILD`; fund the savings address with `../bitkit-android/lsp POST /regtest/chain/deposit` then `/mine`, wait ~20 s. The confirm-change journey needs the staging regtest backend (default `E2E_BUILD` targets the local backend, which cannot open a Blocktank channel).
- E2E `bitkit-e2e-tests/test/specs/transfer.e2e.ts`, describe `@transfer`: `@transfer_1` (default plus custom capacity, two channels; tags `@transfer_staging`, `@staging`), `@transfer_max` (`@transfer_staging`, `@staging`), `@transfer_2 @ios_gate` (external LND channel, LN payment, close to savings). CI: `e2e-staging.yml` shard `transfer` greps `@transfer_staging`; `e2e-tests.yml` greps `@ios_gate`.
- Other specs using transfer helpers (`transferSavingsToSpending`, `transferSpendingToSavings` in `test/helpers/actions.ts`): `multiaddress.e2e.ts` `@multi_address_2` (`@multi_address_staging`), `bitkit-e2e-tests/test/specs/lnurl.e2e.ts` `@lnurl_1` (`ConnectButton`).
- Mainnet: `bitkit-e2e-tests/test/specs/mainnet/channel-order.e2e.ts` `@channel_order_mainnet`/`@channel_order_1` restores `CHANNEL_ORDER_SEED` (or `CJIT_SEED`) and reads fees on `SpendingConfirm`. Its `getMoneyTextValues` throws on iOS ("supported on Android only").
- Preconditions: `@transfer_1`/`_max` need Blocktank (`BACKEND=regtest`, app built for staging regtest). `@transfer_2` uses `BACKEND=local` docker plus LND (`setupLND`, `connectToLND`). Specs call `ensureLocalFunds`, `initElectrum`, `reinstallApp`.
- Unit tests: `BitkitTests/TransferViewModelTests.swift` (limits, settling, order reuse, fee increase), `SpendingConfirmTotalTests.swift`, `SavingsSwapTests.swift`, `TransferServiceActivityTests.swift`, `BitkitTests/ChannelPurchaseFlow.swift` (class `PaymentFlowTests`, `testchannelPurchaseFlow`: live regtest deposit, `blocktank.newOrder`, pays it; needs network).

## What proves it
- After the swipe: `LightningSettingUp`; later `TransferSuccess` and `TransferSuccess-button`, then Home (`ActivitySavings`, `ActivitySpending`).
- Toast `SpendingBalanceReadyToast` when the channel is usable (`AppViewModel` channel-ready event); spending balance equals the entered amount (`settleAndExpectSpendingBalance` mines blocks until it does).
- Home `ActivityShort-0` contains "Transfer" and "-" (`expectHomeTransferRows`).
- Channel detail (Settings > Advanced > Channels > `Channel`): `TotalSize` 250 000 for the custom 100 000 + 150 000 channel, `IsUsableYes`; "Processing payment" may show before settle.
- External: `ExternalSuccess`; `@transfer_2` closes via `TransferToSavings`, `SavingsIntro-button`, `AvailabilityContinue`, `GRAB`, `TransferSuccess`, and Channels no longer lists "Connection 1".
- Over-max journeys: toasts `SpendingAmountExceededToast`, `SpendingAdvancedExceededToast`, `ExternalAmountExceededToast`; value does not exceed the stated maximum; `NRemove` lowers it.
- Confirm-change journey: after the swipe `LightningSettingUp` within 90 s.

## Not covered by tests
- Boltz swap path (`.swap`, quote, slider, `.settling` state): only unit tests (`SavingsSwapTests.swift`); mainnet plus a dev flag, no journey or e2e.
- Force close sheet and coop-close retry loop: no journey or e2e found; `TransferViewModel` retry timing has no unit test I found.
- Savings advanced channel selection (`SavingsAdvancedView`), multi-channel close: none found.
- "Fees changed" toast on swipe (higher total): unit tests only (the journey says so).
- No-funds alert, geo-blocked states, `FundLnUrl`, node-URI paste/scan, `LnurlChannel` error branches: none found.
- Order restart (`startWatchingOrderFromRestart`), expired order settling: none found beyond unit tests of order reuse.
- Could not determine whether `@transfer_1` runs in CI: e2e `AGENTS.md` says it is not in the app `e2e-staging.yml` yet, but that workflow greps `@transfer_staging`, which `@transfer_1` carries.

## Gotchas
- `journeys/transfer/spending-confirm-amount-change.xml` taps `SpendingIntroContinue`, which does not exist; the code id is `SpendingIntro-button`. Treat as a stale journey id.
- The max starts at 0 behind a spinner; wait for `SpendingAmountAvailable`. The cap can be below "Available"; Continue stays enabled at the cap (input is capped). On regtest `SpendingAdvancedMin` can exceed `SpendingAdvancedMax` once LSP headroom is used (`journeys/amount-limits/README.md`).
- Advanced screen disables the number pad while the max settles (`isSettlingAdvancedCapacity`); the window is shorter than a snapshot.
- Toasts last `Toast.visibilityTimeShort`; assert with `wait-for-ui` right after the keypress.
- `SettingUpView.onAppear` mines one regtest block after 5 s through the Blocktank regtest API (`Env.network == .regtest`).
- `TransferViewModel.currentOrder` reuses an order only while state is `created`, not funded, and expiry is more than 60 s away.
- E2E asserts transfer rows on Home `ActivityShort-*` because timed sheets can cover `ActivitySavings`.
- `docs/` and `Docs/` are one directory on a case-insensitive filesystem; git tracks `Docs/`. No transfer doc exists there.
