# Security: PIN, biometrics, app lock, privacy toggles, wipe

Scope: PIN setup / change / disable, app lock (`AuthCheck`), PIN for payments, biometrics, forgot PIN and failed-attempt wipe, hide balance, reset wallet (wipe). Phrase backup is in `backup.md`; recovery-mode wipe in `onboarding.md`; where the payment PIN prompt sits inside send is in `send.md`.

## What it does
- PIN: 4 digits stored in the keychain (`.securityPin`, `SettingsViewModel.setPin/pinCheck/changePin/removePin` in `Bitkit/ViewModels/Extensions/SettingsViewModel+PIN.swift`). `settings.pinEnabled` mirrors keychain existence.
- App lock: `AppScene.isPinVerified` starts false and is set true on appear only if no PIN. With a PIN, `existingWalletContent` shows `AuthCheck` (PIN pad, optional Face/Touch ID) instead of `MainNavView` on cold start and after every return from the background (`handleScenePhaseChange`: `.background` sets `isPinVerified = false`). `pinOnLaunch` UserDefault is only set by RN migration.
- Biometrics: `settings.useBiometrics`; `AuthCheck` auto-prompts on appear when enabled and available; a "use biometrics" button appears after one failure. Setup offers it after the PIN (`SecurityBiometrics`), or `SecurityNoBiometrics` (skip / phone settings) when `Env.biometryType == .none`. The simulator normally has no enrolled biometrics, so e2e takes the no-biometrics path.
- Failed attempts: `Env.pinAttempts = 8`, counter `pinFailedAttempts`. Errors: "N attempts remaining" (id `AttemptsRemaining`), last attempt (id `LastAttempt`); the 8th wrong PIN calls `AppReset.wipe(toastType: .warning)`. Tapping the error text opens `ForgotPinSheet` (`SheetID.forgotPin`) whose reset button also wipes.
- PIN for payments: `settings.requirePinForPayments` (+ biometrics if `useBiometrics`); `SendConfirmationView` / `LnurlPayConfirm` call `requestPinCheck` before paying; `SendSheet` pushes `SendRoute.pin` -> `SendPinScreen` (`Bitkit/Views/Wallets/Send/SendPinScreen.swift`, same attempt/wipe rules, title "Enter PIN Code"). With biometrics on and available, `BiometricAuth.authenticate()` replaces the PIN screen.
- Privacy toggles: `swipeBalanceToHide`, `hideBalanceOnOpen`, `readClipboard`, `warnWhenSendingOver100`. Disabling swipe forces `hideBalance = false`; `hideBalanceOnOpen` sets `hideBalance = true` at `SettingsViewModel` init.
- Reset wallet: `ResetScreen` -> confirm alert -> `AppReset.wipe` (stops node, wipes LDK/core DB, keychain, UserDefaults, installation marker, paykit endpoints, logs on regtest), then `session.bump()` rebuilds app state and shows onboarding; toast "wiped" (`security__wiped_title`). PIN settings are also reset after a backup restore (PIN is never backed up).

## How a user reaches it
- Settings -> Security (`Bitkit/Views/Settings/SecuritySettingsView.swift`; e2e `openSettings('security')`): `PINCode` (-> `ChangePinScreen`), `EnablePinForPayments` (only with PIN; toggle goes through `PinCheckView`), `UseBiometryInstead` (only with PIN and biometrics available), `SendAmountWarning`, `SwipeBalanceToHide`, `HideBalanceOnOpen`, `AutoReadClipboard`, `ResetAndRestore`, `BackupWallet`, `BackupSettings`.
- `ChangePinScreen` ids: `EnablePin` (no PIN), `ChangePIN`, `DisablePin` (PIN set). Each opens sheet `.security` with `SecurityConfig(initialRoute:)` `.setupPin` / `.changePin` / `.disablePin`.
- Setup: pad ids `PinPad`, `N0`..`N9`, `NRemove`; `WrongPIN` (mismatch); then `SkipButton` (no-biometrics step) or biometrics toggle; success screen toggle `ToggleBioForPayments` ("PIN for payments"), button label `OK`. Change: current PIN, new PIN, retype (mismatch -> `WrongPIN`), `OK`. Disable: enter PIN, sheet closes.
- Suggestion card `Suggestion-secure` opens sheet `.security` at `SecurityIntro` (ids `SecureWallet`, `SecureWalletContinue`, `SecureWalletCancel`).
- Lock screen: relaunch (`launchFreshApp`) -> `PinPad`. Forgot PIN: tap the `AttemptsRemaining`/`LastAttempt` text.
- Hide balance: swipe right on `TotalBalance`; reveal `ShowBalance`; toasts `BalanceHiddenToast` (see `home.md`).
- Reset: `ResetAndRestore` -> `ResetScreen` (buttons without ids, labels "Reset Wallet" and "Back Up First"); confirm is a native alert with destructive button "Yes, Reset".

## Code
- Views: `Bitkit/Views/Security/AuthCheck.swift`, `Bitkit/Views/Security/PinCheckView.swift`, `Bitkit/Views/Settings/SecuritySettingsView.swift`, `Bitkit/Views/Settings/Security/ChangePinScreen.swift`, `Bitkit/Views/Settings/Security/ResetScreen.swift`, `Bitkit/Views/Settings/Security/SecuritySheet/SecuritySheet.swift`, `Bitkit/Views/Settings/Security/SecuritySheet/SecurityIntro.swift`, `Bitkit/Views/Settings/Security/SecuritySheet/SecuritySetupPin.swift`, `Bitkit/Views/Settings/Security/SecuritySheet/SecurityBiometrics.swift`, `Bitkit/Views/Settings/Security/SecuritySheet/SecurityNoBiometrics.swift`, `Bitkit/Views/Settings/Security/SecuritySheet/SecuritySuccess.swift`, `Bitkit/Views/Settings/Security/SecuritySheet/SecurityChangePin.swift`, `Bitkit/Views/Settings/Security/SecuritySheet/SecurityChangePinSuccess.swift`, `Bitkit/Views/Settings/Security/SecuritySheet/SecurityDisablePin.swift`, `Bitkit/Views/Sheets/ForgotPinSheet.swift`, `Bitkit/Views/Wallets/Send/SendPinScreen.swift`, `Bitkit/Components/PinInput.swift`, `Bitkit/Components/NumberPad.swift`.
- Enums: `SecurityRoute` (`intro, setupPin, biometrics, noBiometrics, success, changePin, changePinSuccess, disablePin`), `SheetID.security`, `SheetID.forgotPin`, `Route.changePin`, `Route.reset`, `PinAttemptOutcome`.
- Logic: `SettingsViewModel(+PIN)`, `Bitkit/Utilities/BiometricAuth.swift`, `Bitkit/Utilities/AppReset.swift`, `AppScene` (`isPinVerified`, `handleScenePhaseChange`, `existingWalletContent`), `Bitkit/Components/MoneyStack.swift` (hide gesture), `Bitkit/Components/MoneyText.swift`.

## How to drive it
- e2e `bitkit-e2e-tests/test/specs/security.e2e.ts`, describe `@security @ios_nightly`: `@security_1` ("Can setup PIN"): enable PIN with wrong retype, skip biometrics, enable "PIN for payments", relaunch and unlock, receive funds, send with PIN (`dragOnElement('GRAB')`, text "Enter PIN Code", `SendSuccess`), change PIN (wrong current PIN -> `AttemptsRemaining`, wrong confirm -> `WrongPIN`), relaunch, disable PIN, relaunch without prompt, re-enable, 7 wrong PINs (`AttemptsRemaining`, then `LastAttempt`) and the 8th wipes: text "Privacy Policy" and `Continue` visible. Needs funds (`ensureLocalFunds`, `initElectrum`), `receiveOnchainFunds`, regtest address from `getExternalAddress`. Helpers `multiTap('N1', 4)`.
- e2e `settings.e2e.ts` `@settings_06` ("Can swipe to hide balance", `@settings @ios_nightly`): swipe `TotalBalance`, `ShowBalance`, toggles `SwipeBalanceToHide`, `HideBalanceOnOpen`. `@settings_07` covers `ResetAndRestore` navigation only (backup flow, see `backup.md`).
- Journey `journeys/security/wallet-wipe-new-profile.xml` ("new profile after wallet wipe"): Settings -> Security -> `ResetAndRestore` -> Reset Wallet -> confirm -> onboarding -> new wallet -> profile creation. Needs a disposable unfunded wallet with Paykit enabled, a Pubky test network, English device.
- Unit tests: none found for PIN/`AuthCheck`/`SettingsViewModel+PIN` in `BitkitTests/`; `OrphanedKeychainTests`/`KeychainTests` touch keychain only.

## What proves it
- PIN on: `PinPad` displayed after relaunch; correct PIN -> `TotalBalance` displayed. PIN off: relaunch shows `TotalBalance` with no `PinPad`.
- Wrong PIN: `WrongPIN` / `AttemptsRemaining` / `LastAttempt` text element visible.
- Payment PIN: text "Enter PIN Code", then `SendSuccess`.
- Wipe: onboarding terms screen (text "Privacy Policy", `Continue`); toast "Wallet Data Deleted" (`security__wiped_title`, not asserted by e2e).
- Hide balance: `ShowBalance` displayed / absent; `BalanceHiddenToast`.

## Not covered by tests
- Biometric paths (`SecurityBiometrics`, `UseBiometryInstead`, `AuthCheck` biometric button, `BiometricAuth` in payments): simulator has no enrolled biometrics; could not find any test.
- `ForgotPinSheet` reset, `PinCheckView` from settings, `SendPinScreen` wipe path (`EnablePinForPayments` toggle), PIN gate in `RecoveryScreen`, `LnurlPayConfirm` PIN, lock-on-background (only relaunch is tested).
- `ResetScreen` full wipe path in e2e (only the journey drives it; confirm alert not in e2e).
- Privacy toggles `AutoReadClipboard`, `SendAmountWarning`; hide-on-open after relaunch (iOS assertion skipped, see Gotchas).
- Wipe failure toast ("Wipe Failed"), disable-PIN error path.

## Gotchas
- After 8 wrong PINs the app wipes the wallet and shows onboarding; never run on a wallet worth keeping. `pinFailedAttempts` persists across relaunches until a correct PIN.
- Wrong PIN confirmation while changing PIN or setting PIN does not consume attempts (only `pinCheck` does).
- `@settings_06`: iOS does not assert the balance is hidden after restart (comment references bitkit-ios issue #260); Android does.
- `SkipButton` also exists on the onboarding slider (`OnboardingToolbar`) and on `SecurityNoBiometrics`.
- `AuthCheck` locks on `.background`, not `.inactive`.
- Identifiers `AttemptsRemaining`/`LastAttempt` replace `WrongPIN` on the same text element for failed attempts; `WrongPIN` is the fallback id.
- e2e reset of keychain between tests: `reinstallApp()` runs `simctl keychain reset` (iOS keychain survives uninstall).
