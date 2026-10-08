# Onboarding, wallet creation and restore

Scope: first launch with no wallet (terms, intro slider, new wallet, passphrase wallet, restore from recovery phrase), the post-create/restore initializing, success and error screens, splash, and the Recovery mode screen. Backup of the phrase after creation is in `backup.md`; PIN is in `security.md`.

## What it does
- No keychain mnemonic (`Keychain.exists(.bip39Mnemonic(index: 0))` false, `WalletViewModel.walletExists == false`) shows `TermsView` inside a `NavigationStack` (`Bitkit/AppScene.swift` `onboardingContent`).
- `TermsView` -> `IntroView` -> `OnboardingSlider` (3 slides + create/restore page).
- New wallet: `StartupHandler.createNewWallet(bip39Passphrase:)` (`Bitkit/Utilities/StartupHandler.swift`) generates a 12-word mnemonic, saves it (and a non-empty passphrase) to the keychain, sets address type `nativeSegwit`. An empty passphrase counts as none.
- Restore: `RestoreWalletView` takes 12 words (fixed `wordCount = 12`), optional BIP39 passphrase, optional SeedQR scan. Validates with `validateMnemonic`; invalid words/checksum show red messages. `restoreWallet()` sets `wallet.isRestoringWallet`, `BackupService.setRestoring(true)`, arms the received-sheet suppression (`pendingRestoreActivitySeenSince`), calls `monitorAllAddressTypes()`, then `StartupHandler.restoreWallet`.
- After either path `AppScene.handleWalletExistsChange` starts the node. A restore (or a pending VSS restore) runs `restoreWalletBackupAndStart` (VSS or RN backup, whichever is newer, see `backup.md`) while `InitializingWalletView` shows ("Setting up your wallet", percent spinner, rocket).
- Restore end states: `WalletRestoreSuccess` (button "Get Started") or `WalletRestoreError` ("Try Again"; shown when the backup restore failed or node state is `.errorStarting`).
- `RecoveryRouter`/`RecoveryScreen`: reduced screen replacing the whole app while `showRecoveryScreen` is true (see Code). Actions: export logs, display seed, contact support (mailto), reset graph, wipe app.
- Splash: `SplashView` overlay above `mainContent`, hidden (0.2s fade, 0.2s delay) once `walletExists != nil`, removed after 0.4s; skipped once after a wipe or graph reset (`session.skipSplashOnce`).

## How a user reaches it
Fresh install, launch:
1. `TermsView`: button title "Continue" (no identifier set in `Bitkit/Views/Onboarding/TermsView.swift`; Appium `~Continue` matches the label, English only).
2. `IntroView`: `GetStarted` (-> slide 0) or `SkipIntro` (-> slide page 3).
3. `OnboardingSlider`: `Slide0`, `Slide1`, `Slide2`; `SkipButton` jumps to page 3; on page 3 the toolbar shows `Passphrase` ("Advanced setup").
4. Page 3 `CreateWalletView`: `NewWallet`, `RestoreWallet`.
5. New wallet with passphrase: `Passphrase` -> `CreateWalletWithPassphraseView`: `PassphraseInput`, `CreateNewWallet` (disabled while the trimmed passphrase is empty).
6. Restore: `RestoreWallet` -> `MultipleWalletsView` (`MultipleDevices-button`) -> `RestoreWalletView`: `Word-0`..`Word-11` (`Bitkit/Components/SeedTextField.swift`), `RestoreSeedQR` (toolbar), `AdvancedButton` (enabled only for a valid phrase), `PassphraseInput` (after Advanced), `RestoreButton`, `RestoreScrollView`. Pasting 12 whitespace-separated words into `Word-0` fills all fields.
7. Restore success: `GetStartedButton`. Then home (`TotalBalance-primary`, see `home.md`).
8. `WalletRestoreError` and `RecoveryScreen` buttons have no identifiers (found by label).
- Recovery mode: home-screen long-press quick action "Recovery" (`Bitkit/Info.plist` `UIApplicationShortcutItems`) -> `SceneDelegate.handleQuickAction` -> `.quickActionSelected` -> `AppScene.handleQuickAction` sets `showRecoveryScreen`.

## Code
- `Bitkit/AppScene.swift`: `mainContent` (order: Trezor emulator test, migration loading, `showRecoveryScreen`, critical update, `walletContent`), `onboardingContent`, `existingWalletContent`, `initializingContent`, `handleWalletExistsChange`, `startWallet`, `restoreWalletBackupAndStart`, `retryWalletStart`, `handleOrphanedKeychain`, `handleQuickAction`.
- Views: `Bitkit/Views/Onboarding/{TermsView,Tos,IntroView,OnboardingSlider,OnboardingTab,CreateWalletView,CreateWalletWithPassphraseView,MultipleWalletsView,RestoreWalletView,SeedQRCodeScannerView,InitializingWalletView,WalletRestoreSuccess,WalletRestoreError}.swift`, `Bitkit/Views/SplashView.swift`, `Bitkit/LaunchScreen.storyboard`, `Bitkit/Views/OnboardingView.swift` (generic image+text+button layout reused by other screens, not the wallet onboarding flow).
- Recovery: `Bitkit/Views/Recovery/{RecoveryRoute,RecoveryScreen,RecoveryMnemonicScreen}.swift`; `RecoveryRoute` cases `.main`, `.mnemonic`. Seed/wipe are PIN-gated via `PinCheckView` when `settings.pinEnabled`. Wipe uses `AppReset.wipe` (`Bitkit/Utilities/AppReset.swift`).
- State: `WalletViewModel` (`walletExists`, `isRestoringWallet`, `nodeLifecycleState`, `setWalletExistsState()`), `SettingsViewModel` restore flags, `Bitkit/Utilities/StartupHandler.swift`, `Bitkit/Utilities/InstallationMarker.swift`, `Bitkit/Services/MigrationsService.swift`.
- No `Route`/`SheetID` enum case opens these; they are root-level screens switched by `AppScene` state.

## How to drive it
- e2e `bitkit-e2e-tests/test/specs/onboarding.e2e.ts`, describe `@onboarding @ios_nightly` (iOS nightly shard, not Mini): `@onboarding_1` (terms, slides by swipe, `SkipButton`, `NewWallet`), `@onboarding_2` (passphrase wallet, then `getSeed`, `restoreWallet(seed,{passphrase})`, compares receive addresses and Address Viewer `Address-0`/`Address-1`).
- Helpers: `completeOnboarding()` (`Continue`, `SkipIntro`, `NewWallet`, wait for `TotalBalance-primary`), `restoreWallet()` (`bitkit-e2e-tests/test/helpers/actions.ts`; iOS pastes the phrase via `pasteIOSText('Word-0', seed)`), `waitForSetupWalletScreenFinish` (waits for text "SETTING UP\nYOUR WALLET" to disappear, 150 s). `reinstallApp()` removes the app and runs `simctl keychain reset` on iOS (`test/helpers/setup.ts`).
- Restore is exercised by most specs through `restoreWallet`; `backup.e2e.ts` and `migration.e2e.ts` use it (see `backup.md`).
- Journey: `journeys/onchain-receive/restore-recent-receive-stays-silent.xml` ("recent receive stays silent after a seed restore") drives terms -> `SkipIntro` -> `RestoreWallet` -> `MultipleDevices-button` -> paste into `Word-0` -> `RestoreButton` -> `GetStartedButton`. Needs a throwaway simulator, `xcrun simctl keychain booted reset`, regtest + `../bitkit-android/lsp` (see `journeys/README.md`). Journey `journeys/security/wallet-wipe-new-profile.xml` re-runs onboarding after a wipe.
- Preconditions: new-wallet tests need no funds. Local runs use an `E2E_BUILD` app (`journeys/README.md`).

## What proves it
- New wallet: `TotalBalance-primary` displayed; empty-wallet text "TO GET STARTED SEND BITCOIN..." (`elementByText('TO GET')` in `@onboarding_1`).
- Restore: `GetStartedButton` displayed after the setting-up screen, then `TotalBalance-primary`.
- Passphrase: restored wallet receive address equals the original (`@onboarding_2`).

## Not covered by tests
- 24-word restore: UI is fixed to 12 words (`RestoreWalletView.wordCount`), so not reachable; `StartupHandler.restoreWallet` accepts 24.
- Invalid-phrase messages, SeedQR scan/photo import (only `SeedQRCodeDecoderTests` in `BitkitTests/`), `RestoreSeedQR`, autocomplete accessory (`SeedInputAccessory`).
- `WalletRestoreError`/"Try Again", `didWalletBackupRestoreFail`, `.errorStarting` retry: only `BitkitTests/NodeStartRetryTests.swift` (node restart policy) and `BitkitTests/InitializingWalletViewTests.swift` cover logic.
- `RecoveryScreen` (all five actions), quick action: no journey, e2e or unit test found.
- Geo-blocked slide note (`GeoService.isGeoBlocked` on `Slide1`), offline start, language/localized labels.
- Orphaned keychain wipe on reinstall: unit tests `OrphanedKeychainTests`, `InstallationMarkerTests` only.
- `CreateWalletWithPassphraseView` with whitespace-only input; passphrase restore with a wrong passphrase.

## Gotchas
- The offline overlay (`Bitkit/Views/Offline/*`, ids `ConnectionIssuesScreen`/`ConnectionIssuesSheetScreen`) is not part of onboarding; it overlays transfer, shop, send and receive screens. During onboarding, `startWallet` returns early when `network.isConnected` is false; `handleNetworkChange` restarts the node on reconnect (`AppScene.swift`).
- Keychain survives app removal on iOS simulators: reset with `xcrun simctl keychain booted reset` or onboarding will not show (journey description; `resetBootedIOSKeychain`). The app also wipes orphaned keychain data at launch when `InstallationMarker` is missing.
- Terms `Continue` has no accessibility identifier; label match is English-only.
- After a restore, `WalletRestoreSuccess` sets `app.backupVerified = true` and `pendingRestoreAddressTypePrune` unless monitored types came from the backup.
- Restore can take long: e2e waits up to 180 s for `GetStartedButton`.
- `RecoveryScreen` buttons stay disabled for 1 s after appear (`locked`).
- `walletExists == nil` (before keychain check) renders nothing under the splash.
