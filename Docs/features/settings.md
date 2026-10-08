# Settings (general, security/privacy entry, dev, support)

Scope: Settings screen tabs General, Security (entry rows only; PIN, backup and reset detail in `security.md` and `backup.md`), Support, App Status and Dev Settings. The Advanced tab is in `settings-advanced.md`. Notification and widget settings detail: `notifications.md`, `widgets.md`.

## What it does
- General tab (`GeneralSettingsView`): language, local currency, primary unit (Bitcoin / fiat) plus denomination (modern / classic), widgets settings, tags (row hidden while `tagManager.lastUsedTags` is empty), default transaction speed, contact-payments toggle (only with Paykit UI active and a Pubky profile), Quickpay, notifications, hardware wallets (row only; screen in `hardware-wallet.md`).
- Security tab (`SecuritySettingsView`): backup wallet (opens `.backup` sheet), data backups, reset and restore, PIN row, then (PIN enabled only) require-PIN-for-payments and biometrics toggles, then "warn over $100", swipe-balance-to-hide, hide-balance-on-open, auto-read clipboard.
- Transaction speed: tiers `instant/fast/normal/slow` plus `custom` (sat/vB via `CustomSpeedView`); stored as `defaultTransactionSpeed`.
- Quickpay: `enableQuickpay` toggle, amount threshold slider and daily-limit multiplier slider; first visit shows `QuickpayIntroView`. Values feed `QuickPayLimits` and `PaymentNavigationHelper`.
- Support (`SupportScreen`): report issue (POST to `Env.supportApiUrl`), help link, App Status, legal, share, version row. Tapping the version row 5 times toggles `showDevSettings` (default `Env.isDebug`) and shows a toast.
- App Status (`AppStatusView`): rows internet, electrum, lightning node, lightning connection, backup; pull-to-refresh syncs and restarts a stopped node.
- Dev Settings (`DevSettingsView`, visible when `showDevSettings`): Blocktank Regtest (regtest only), Override Fees (regtest only), LDK, VSS, Probing Tool, Orders, Trezor, Swaps and savings-swap toggle, Legacy Close Recovery, Paykit UI toggle (+ subscription clock offset), generate/reset test activities, logs, export logs, test push, simulate crash, wipe. LDK/VSS/Probing detail in `settings-advanced.md`.

## How a user reaches it
- Home: `HeaderMenu` (burger) -> `DrawerSettings` -> `MainSettingsScreen`. Tabs: `Tab-general`, `Tab-security`, `Tab-advanced` (built from the lowercased English tab title in `SegmentedControl`).
- Support: `HeaderMenu` -> `DrawerSupport`. App Status: `HeaderMenu` -> `DrawerAppStatus` (or Support -> `AppStatus`, or the home header status icon).
- General rows (all `NavigationLink`, id on the row): `LanguageSettings`, `CurrenciesSettings`, `UnitSettings`, `WidgetsSettings`, `TagsSettings`, `TransactionSpeedSettings`, `ContactPaymentsToggle`, `QuickpaySettings`, `NotificationsSettings`, `HardwareWalletsSettings`. Row value text has id `Value`.
- Currency rows: tapping selects and pops back. `Currency-<quote>` is set as `testIdentifier` but `SettingsRow` only applies it to toggles, so it does not exist at runtime (e2e taps by text, e.g. `EUR (€)`).
- Unit screen: Bitcoin / fiat rows have no explicit id (e2e calls `tap('Bitcoin')` / `tap('USD')`, which resolves by label), `DenominationModern`, `DenominationClassic`.
- Transaction speed rows: ids `instant`, `fast`, `normal`, `slow`, `custom` (`feeKeyComponent`); custom screen number pad `N0`..`N9` and `Continue`.
- Quickpay: `QuickpayIntro` (first visit), `QuickpayToggle`, `QuickpayAmountSlider`, `QuickpayDailyLimitSlider`.
- Security rows: `BackupWallet`, `BackupSettings`, `ResetAndRestore`, `PINCode`, `EnablePinForPayments`, `UseBiometryInstead`, `SendAmountWarning`, `SwipeBalanceToHide`, `HideBalanceOnOpen`, `AutoReadClipboard`.
- Support rows: only `AppStatus`, `DevOptions` (version row), `AboutLogo` have ids; report issue / help / legal have none. App Status rows: `Status-internet`, `Status-electrum`, `Status-lightning_node`, `Status-lightning_connection`, `Status-backup`.
- Dev Settings: Advanced tab -> `DevSettings` (needs `showDevSettings`). Ids inside: `Trezor`, `SavingsSwapToggle`, `LegacyRnRecovery`, `PaykitUiToggle`, `SubscriptionClockOffset[-days]`; toasts `DevModeEnabledToast`, `DevModeDisabledToast`, `PaykitUiEnabledToast`, `PaykitUiDisabledToast`.

## Code
- `Bitkit/Views/Settings/MainSettingsScreen.swift` (enum `SettingsTab`), `GeneralSettingsView.swift`, `SecuritySettingsView.swift`, `SupportScreen.swift`, `AppStatusView.swift`, `DevSettingsView.swift`, `LogView.swift`.
- `Bitkit/Views/Settings/General/` (`LanguageSettingsScreen`, `LocalCurrencySettingsView`, `DefaultUnitSettingsView`, `TagSettingsView`, `WidgetsSettingsScreen`), `TransactionSpeed/`, `Quickpay/`, `Support/` (`ReportIssue`, `ReportSuccess`, `ReportError`).
- State: `Bitkit/ViewModels/SettingsViewModel.swift` (`@AppStorage` keys such as `defaultTransactionSpeed`, `enableQuickpay`, `swipeBalanceToHide`, `showWidgets`), `CurrencyViewModel.swift`, `Bitkit/Managers/LanguageManager.swift`, `TagManager.swift`, `Bitkit/Services/CurrencyService.swift`, `Bitkit/Utilities/QuickPayLimits.swift`, `QuickPayPaymentCoordinator.swift`.
- Routes (`NavigationViewModel.Route`): `.settings`, `.languageSettings`, `.currencySettings`, `.unitSettings`, `.tagSettings`, `.widgetsSettings`, `.transactionSpeedSettings`, `.customSpeedSettings`, `.quickpay`, `.quickpayIntro`, `.notifications`, `.notificationsIntro`, `.hardwareWalletsSettings`, `.support`, `.reportIssue(prefill)`, `.appStatus`, `.devSettings`, `.logs`. Registered in `Bitkit/MainNavView.swift` (~line 665-720). Only sheet used: `.backup` from the Backup row.
- Env: `Bitkit/Constants/Env.swift` (`supportApiUrl`, `helpUrl`, `termsOfServiceUrl`, `isE2E`).

## How to drive it
- e2e `bitkit-e2e-tests/test/specs/settings.e2e.ts`, describe `@settings @ios_nightly`, helpers `openSettings(tab)`, `openSupport()`, `doNavigationClose()` in `test/helpers/navigation.ts`. Each test starts with `launchFreshApp()`; `before` reinstalls and onboards.
  - `@settings_01` currency switch (USD/EUR via text). `@settings_02` unit + `DenominationClassic`. `@settings_03` transaction speed fast/custom/normal. `@settings_04` tags row hidden then delete tag (`Tag-<tag>-delete`). `@settings_05` Support screen (`AboutLogo`). `@settings_06` swipe-to-hide balance (`SwipeBalanceToHide`, `HideBalanceOnOpen`). `@settings_07` backup wallet seed reveal and verify (`BackupWallet`, `ResetAndRestore`). `@settings_12` reset suggestions (Widgets settings). `@settings_13` dev mode multi-tap (`multiTap('DevOptions', 5)`). `@settings_14` app status rows.
- Journeys: none for settings. `journeys/README.md` has no settings suite.
- Preconditions: the general tests import no regtest, LSP or LND helper and fund nothing; they need an `E2E_BUILD` app (default backend local: `Env.electrumServerUrl` = `tcp://127.0.0.1:60001`). Advanced-tab tests: see `settings-advanced.md`.

## What proves it
- Currency: `MoneyFiatSymbol` under `TotalBalance-primary` shows `$`, `€` or `₿`. Unit: `UnitSettings`/`Value` text and balance text `0.00`, `0`, `0.00000000`. Speed: `TransactionSpeedSettings`/`Value` matches `/.*Fast/`, `/.*Custom/`, `/.*Normal/`.
- Tags: `TagsSettings` absent with no tags, tag text gone after delete. Balance hide: `ShowBalance` visible/hidden, toast `BalanceHiddenToast` (best effort).
- Dev mode: toasts `DevModeDisabledToast` / `DevModeEnabledToast`, `DevSettings` row appears/disappears.
- App status: five `Status-*` ids displayed. Support: `AboutLogo` displayed.

## Not covered by tests
- No e2e or journey for: language switch, contact-payments toggle, Quickpay settings (only the intro sheet is dismissed by helpers), PIN-dependent toggles (`EnablePinForPayments`, `UseBiometryInstead`; see `security.md`), `SendAmountWarning`, `AutoReadClipboard`, report issue form (network POST), help/legal/share rows, data backups row, hardware wallets row, Dev Settings items other than the toggle and visibility, `LogView`, export logs.
- Unit tests: `BitkitTests/CurrencyTests.swift`, `FiatFormattingTests.swift`, `QuickPayLimitsTests.swift`, `QuickPaySpendStoreTests.swift`, `QuickPayPaymentCoordinatorTests.swift`, `SettingsUrlValidationTests.swift` (Electrum/RGS URL validators). No UI test opens a settings screen (`BitkitUITests` has contact-import and Trezor tests only).
- Custom transaction speed value persistence beyond the `Value` text: could not determine.

## Gotchas
- Dev Settings is visible by default only because `showDevSettings` defaults to `Env.isDebug`; `settings_13` assumes the E2E build is Debug and a Release build hides it until 5 taps.
- `Tab-*` ids derive from the English title; on a non-English device they change (`journeys/README.md`).
- Settings tab content is swipeable (`swipeSegmentedTabs`); drawer `DrawerWallet` is the e2e way home (`doNavigationClose`).
- `settings_06` skips the "hidden after restart" assertion on iOS (bitkit-ios issue 260 comment in the spec).
- Toggle rows expose the `testIdentifier` on the `Toggle` only (`SettingsRow`); `NotificationsSettings` toggles have no id.
- `ContactPaymentsToggle` is rendered only with `PaykitFeatureFlags.isUIAvailable`, the Paykit UI flag on, and an authenticated Pubky profile; `GeneralSettingsView.task` also calls `ContactPaymentsService.enableAllPaymentOptions()` and auto-enables contact payments on first visit.
