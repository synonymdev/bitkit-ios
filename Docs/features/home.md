# Home screen and wallet balances

Scope: `HomeScreen` (wallet page + widgets page), balances, savings and spending wallet screens, suggestion cards, pull to refresh, buy-bitcoin screen, timed sheets (high balance and the queue). Widgets themselves are in `widgets.md`; activity list in `activity.md`; drawer/settings in `settings.md`.

## What it does
- `HomeScreen` is the root of `MainNavView`'s `NavigationStack`. A vertical paging `ScrollView` (id `HomeScrollView`) holds page 0 `HomeWalletView` and, if `settings.showWidgets`, page 1 `HomeWidgetsView`. `scrollPosition` 0/1 drives the header edit button (page 1 only).
- `HomeWalletView`: `MoneyStack` headline total (on-chain + lightning + watch-only hardware sats), two balance cards (savings, spending) linking to `Route.savingsWallet` / `.spendingWallet`, hardware wallet grid when paired, `ActivityLatest` when there is activity (plus `WidgetsOnboardingView` until dismissed), else `WalletOnboardingView(.home)` empty-state text.
- `MoneyStack`: tap toggles primary display bitcoin/fiat (one-time toast `BalanceUnitSwitchedToast`); horizontal swipe (>= 50 pt) toggles `settings.hideBalance` when `swipeBalanceToHide` (one-time toast `BalanceHiddenToast`); eye button `ShowBalance` reveals. Hidden amounts render as dots (`MoneyText`).
- `SavingsWalletScreen` / `SpendingWalletScreen`: balance, `IncomingTransfer` banner, transfer button, per-wallet `ActivityList`, "Show all". Empty state `WalletOnboardingView(.savings/.spending)` when balance 0 and no activity of that kind. Their own `.refreshable` runs `wallet.sync()` + `activity.syncLdkNodePayments()`.
- Pull to refresh on Home (page 0 only): custom UIKit observer, threshold 80 pt, runs `currency.refresh()` (feedback wait capped at 10 s) and, if node `.running`, `wallet.sync()` + `syncLdkNodePayments()`; spinner overlay under the header.
- Suggestion cards (`Bitkit/Components/Widgets/Suggestions.swift`, shown by the Suggestions widget on page 1): max 4 from an ordered list chosen by balance state (`empty`/`onchain`/`spending`), skipping completed (backup verified, PIN on, notifications on, quickpay on, profile authenticated, hardware paired) and dismissed (`SuggestionsManager`, UserDefaults `dismissedSuggestions`). Widget hides itself when no cards (unless editing).
- Timed sheets: `TimedSheetManager` shows at most one sheet, 2 s after `HomeScreen` appears (or onboarding root for app update), highest priority first, each once per session: backup (high), app update / high balance / notifications (medium), quickpay (low).
- `BuyBitcoinView`: intro-style screen, button opens `https://bitcoin.org/en/exchanges` in the browser (code has a TODO to hide the card).

## How a user reaches it
- Launch with a wallet (and PIN verified, see `security.md`) -> `HomeScreen`. Ids: `HomeScrollView`, `TotalBalance` (container) with `TotalBalance-primary` / `TotalBalance-secondary`, `MoneyText` inside, `MoneyFiatSymbol`, `ActivitySavings`, `ActivitySpending` (balance card amounts; tapping them navigates), `ShowBalance`, `HeaderMenu` (drawer), `HeaderAppStatus`, `ProfileButton` (Paykit UI only), `PaymentRequestsBell`, `WidgetsEdit`, `WidgetsAdd`, tab bar `Send`, `Receive`, `Scan` (`Bitkit/Components/TabBar/`).
- Savings screen: tap `ActivitySavings`. Spending screen: tap `ActivitySpending`. Both screens reuse ids `HomeScrollView` and `TotalBalance`/`-primary`; buttons `TransferToSpending` (savings), `TransferFromSavings` (spending, only when no spending activity and savings > 0), `TransferToSavings` (spending with channels).
- Suggestion cards: swipe page 1 up (or drawer `DrawerWidgets`); card id `Suggestion-<x>` with `<x>` in `back_up`, `buy`, `hardware`, `invite`, `notifications`, `profile`, `quick_pay`, `secure`, `shop`, `support`, `lightning` (`SuggestionCardData.accessibilityId`); dismiss button `SuggestionDismiss`. Card taps: backup -> sheet `.backup`; secure -> sheet `.security`; buy -> `Route.buyBitcoin` (screen id `BuyBitcoin`, button `BuyBitcoin-button`); lightning -> `.transferIntro`/`.fundingOptions`; support -> `.support`; hardware -> sheet `.hardwareConnect`.
- Drawer ids: `DrawerWallet` (back to page 0), `DrawerWidgets`, `DrawerSettings` etc. (`Bitkit/Components/DrawerView.swift`).
- High balance sheet: appears by itself on Home; ids `HighBalanceSheet`, `HighBalanceSheetDescription`, `HighBalanceSheetContinue` ("Understood"), `HighBalanceSheetCancel` ("Learn More", opens a bitcoin.it wiki URL).

## Code
- `Bitkit/Views/HomeScreen.swift` (pull refresh classes `HomePullRefreshState/Observer/Overlay`, `HomePullRefreshFeedback`), `Bitkit/Views/Home/HomeWalletView.swift`, `Bitkit/Views/Home/HomeWidgetsView.swift`, `Bitkit/Components/MoneyStack.swift`, `Bitkit/Components/MoneyText.swift`, `Bitkit/Components/WalletBalanceView.swift`, `Bitkit/Components/EmptyStateView.swift`, `Bitkit/Components/Header.swift`, `Bitkit/Components/DrawerView.swift`, `Bitkit/Components/SuggestionCard.swift`, `Bitkit/Components/Widgets/Suggestions.swift`, `Bitkit/Managers/SuggestionsManager.swift`.
- `Bitkit/Views/Wallets/SavingsWalletScreen.swift`, `Bitkit/Views/Wallets/SpendingWalletScreen.swift`, `Bitkit/Views/BuyBitcoinView.swift`.
- Balances: `WalletViewModel` (`totalBalanceSats`, `totalOnchainSats`, `totalLightningSats`, `balanceInTransferTo*`), `HwWalletManager.totalSats`, `Bitkit/Managers/BalanceManager.swift`.
- Routes: `Route.savingsWallet`, `.spendingWallet`, `.buyBitcoin`, `.appStatus` (`Bitkit/ViewModels/NavigationViewModel.swift`). Sheets: `SheetID.highBalance`, `.backup`, `.security`, `.appUpdate`, `.notifications`, `.quickpay` (`SheetViewModel.swift`).
- Timed: `Bitkit/Managers/TimedSheets/TimedSheetManager.swift`, `Bitkit/Managers/TimedSheets/BackupTimedSheet.swift`, `Bitkit/Managers/TimedSheets/HighBalanceTimedSheet.swift`, `Bitkit/Managers/TimedSheets/AppUpdateTimedSheet.swift`, `Bitkit/Managers/TimedSheets/NotificationsTimedSheet.swift`, `Bitkit/Managers/TimedSheets/QuickpayTimedSheet.swift`, `Bitkit/Views/Sheets/HighBalanceSheet.swift`; counters `AppViewModel.highBalanceIgnoreCount/Timestamp`, `backupIgnoreTimestamp`, `ignoreHighBalance()`.
- High balance rule: shows if > USD 500 (via `currency.convert`), or > 700 000 sats when no rate; not within 24 h of last dismissal; at most 3 times (`MAX_WARNINGS`).

## How to drive it
- e2e: no dedicated home spec. Home ids are asserted everywhere through `completeOnboarding()` (`TotalBalance-primary`). High balance: `receiveOnchainFunds({sats:100_000_000, expectHighBalanceWarning:true})` -> `acknowledgeHighBalanceWarning()` in `bitkit-e2e-tests/test/specs/backup.e2e.ts` (`@backup_1`, `@backup @ios_nightly`; needs local funds via `ensureLocalFunds()`, Electrum `initElectrum()`). Hide balance: `settings.e2e.ts` `@settings_06` (`@settings @ios_nightly`). Reset suggestions: `@settings_12`. Timed-sheet retrigger helper: `triggerTimedSheetUnlessPresent` -> `doTriggerTimedSheet`.
- Journey: `journeys/home/pull-to-refresh-rates.xml` ("pull to refresh rates"): swipes down on `HomeScrollView`, reads simulator app-group logs for "Currency rates refreshed successfully". Needs network to the rates backend, a simulator UDID, `xcodebuildmcp`.
- Other journeys use home ids only as steps: `ActivitySavings` in `journeys/transfer/spending-confirm-amount-change.xml`, `journeys/amount-limits/transfer-spending-over-max.xml`.
- Regtest/docker: any balance needs `bitkit-docker` + `../bitkit-android/lsp` deposit/mine (`journeys/README.md`); build with `E2E_BUILD`.

## What proves it
- `TotalBalance-primary` (`MoneyText` text, e.g. not "100 000" after a send), `ActivitySavings`/`ActivitySpending` amounts, `ShowBalance` displayed when hidden (`@settings_06`), `BalanceHiddenToast`, `HighBalanceSheetDescription` visible then gone after `HighBalanceSheetContinue`.
- Pull refresh journey: spinner visible under header, new "Currency rates refreshed successfully" log line within 10 s, no "refresh failed" line.

## Not covered by tests
- Savings/Spending screen content (empty states, `IncomingTransfer`, force-close duration), their own pull-to-refresh, `TransferFromSavings`.
- Suggestion card ordering/dismissal/completion per state (no `visibleCards` unit test found in `BitkitTests/`); `SuggestionDismiss`; individual `Suggestion-*` taps other than via other features.
- `BuyBitcoinView` and the `buy` card; hardware grid on Home; `PaymentRequestsBell`.
- Timed sheets: backup/notifications/quickpay timing logic and the 3-times cap of high balance (only `AppUpdateTimedSheetTests` and `SheetViewModelTests` exist); fiat-rate fallback to 700 000 sats.
- Swipe-hide with the toggle off is in `@settings_06`; reveal-by-button `ShowBalance` tap and unit toggle toast: could not determine from e2e.
- Pull-to-refresh logic: `BitkitTests/HomePullRefreshFeedbackTests.swift` (feedback wait/timeout only).

## Gotchas
- `HomeScrollView` and `TotalBalance*` ids also exist on savings/spending screens; check the screen before asserting.
- Timed sheets wait 2 s after Home appears and are one-shot per launch (`removeSheet` after show); e2e re-triggers by opening `HeaderMenu` -> `DrawerSettings` and closing settings (`doTriggerTimedSheet`, `test/helpers/navigation.ts`), which re-enters Home.
- `AppUpdateTimedSheet` never shows when `Env.isE2E`; critical updates replace the whole UI (`AppUpdateScreen`) unless `Env.isDebug`.
- Pull refresh only works on page 0; the refresh observer attaches to the nearest `UIScrollView`.
- `settings_06`: iOS skips the "hidden after restart" assertion (comment cites bitkit-ios issue #260).
- Swipe-hide is disabled in the setting `SwipeBalanceToHide`; turning it off forces `hideBalance = false`.
- A zero-balance wallet shows different suggestion cards than a funded one; set funds before asserting card ids.
