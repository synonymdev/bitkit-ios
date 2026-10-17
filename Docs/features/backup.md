# Recovery phrase backup and data backups (VSS)

Scope: the backup-wallet sheet (show phrase, confirm, passphrase), the backup reminder prompts, the Data Backups settings screen, the `BackupService` upload/restore against VSS, RN-to-native migration and the migration e2e suite. Wallet restore UI is in `onboarding.md`; reset/wipe is in `security.md`.

## What it does
- Recovery phrase backup sheet (`SheetID.backup`, routes `BackupRoute`): `intro` -> `mnemonic` (blurred until `TapToReveal`) -> (`passphrase` only if the wallet has a BIP39 passphrase) -> `confirmMnemonic` (tap shuffled words in order; a wrong word blocks further taps) -> (`confirmPassphrase`: retype the passphrase, Continue disabled until equal) -> `reminder` -> `success` (OK sets `app.backupVerified = true`) -> `devices` -> `metadata` (shows "latest backup" time from `BackupService.getLatestBackupTime`, OK closes the sheet).
- Mnemonic and passphrase are read from the keychain (`.bip39Mnemonic(index: 0)`, `.bip39Passphrase(index: 0)`); views use `screenshotPreventMask`. Long-press copies the phrase only in debug/TestFlight builds (`Env.isDebug || Env.isTestFlight`).
- Reminder prompts: `BackupTimedSheet` (`SheetID.backup`, route `.intro`): shown on Home when `backupVerified != true`, balance > 0 and more than 24 h since `backupIgnoreTimestamp`. "Later" or swiping the sheet away calls `app.ignoreBackup()`. Also suggestion card `back_up` (see `home.md`).
- Data backups: `BackupService` (`Bitkit/Services/BackupService.swift`) uploads encrypted per-category blobs to the VSS server (`Env.vssServerUrl`; mainnet `https://bitkit.to/vss_rs_auth`, otherwise `https://bitkit.stag0.blocktank.to/vss_rs_auth`) via `VssBackupClient`. Categories (`BackupCategory`): `LIGHTNING_CONNECTIONS`, `BLOCKTANK`, `ACTIVITY`, `WALLET`, `SETTINGS`, `WIDGETS`, `METADATA`. Observation starts when the node reaches `.running` (`AppScene.handleNodeLifecycleChange`), changes are debounced 5 s, `scheduleFullBackup()` runs after wallet start. Backups are skipped while restoring or wiping.
- Failure toast: every 60 s `checkForFailedBackups`; a category required for > 30 min emits `backupFailurePublisher` -> toast `settings__backup__failed_title` (not repeated within 10 min).
- Restore (`BackupService.performFullRestoreFromLatestBackup`): order settings, widgets, wallet (fatal on failure; held in keychain `paykitPendingBackupRestore` via `WalletBackupRestoreGate` until applied), activity, metadata, blocktank. PIN settings are reset after restore (PIN is never backed up). `AppScene.restoreFromMostRecentBackup` also checks for an RN remote backup (`RNBackupClient`, `MigrationsService.restoreFromRNRemoteBackup`) and uses it if its timestamp is >= the VSS one, falling back to VSS on error.
- RN -> native migration: on first launch of a native build over RN data, `AppScene.checkAndPerformRNMigration` shows `migrationLoadingContent` (nav title "Wallet Migration", headline "MIGRATING WALLET"; logic in `Bitkit/Services/MigrationsService.swift`); failure shows toast "Migration Failed" and asks for manual restore.

## How a user reaches it
- Settings -> Security (`openSettings('security')` in e2e; drawer `DrawerSettings`) rows in `Bitkit/Views/Settings/SecuritySettingsView.swift`: `BackupWallet` (opens sheet with `BackupConfig(view: .mnemonic)`, skipping the intro), `BackupSettings` (-> `Route.dataBackups` -> `DataBackupsScreen`), `ResetAndRestore` (-> `Route.reset`, its "Backup" button opens the same sheet).
- Sheet ids: `BackupIntroView` (+ `BackupIntroViewDescription`, `BackupIntroViewContinue`, `BackupIntroViewCancel`; ids derived from `SheetIntro` testID), `TapToReveal`, `SeedContainer` (accessibility label = the phrase), `ContinueShowMnemonic`, `Word-<word>` (one per shuffled word, duplicated words share an id), `ContinueConfirmMnemonic`; later steps have only the `OK` label button (reminder, success, devices, metadata) and the passphrase screens have no ids.
- Data Backups screen ids: `BackupScrollView`, `AllSynced` (rendered only when `Env.isE2E` and every category is idle and not required). Per-category retry button has no id.
- Timed prompt appears about 2 s after Home shows (see `home.md`).

## Code
- Views `Bitkit/Views/Backup/BackupSheet.swift`, `Bitkit/Views/Backup/BackupIntro.swift`, `Bitkit/Views/Backup/BackupMnemonic.swift`, `Bitkit/Views/Backup/BackupPassphrase.swift`, `Bitkit/Views/Backup/BackupConfirmMnemonic.swift`, `Bitkit/Views/Backup/BackupConfirmPassphrase.swift`, `Bitkit/Views/Backup/BackupReminder.swift`, `Bitkit/Views/Backup/BackupSuccess.swift`, `Bitkit/Views/Backup/BackupDevices.swift`, `Bitkit/Views/Backup/BackupMetadata.swift`; `Bitkit/Views/Settings/Security/DataBackupsScreen.swift`, `Bitkit/Views/Settings/Security/ResetScreen.swift`.
- `Bitkit/ViewModels/BackupViewModel.swift` (status text "Running"/"Required"/relative time/"Never"), `Bitkit/Models/BackupCategory.swift`, `Bitkit/Models/BackupPayloads.swift`, `Bitkit/Models/SettingsBackupConfig.swift`, `Bitkit/Services/BackupService.swift`, `Bitkit/Services/VssBackupClient.swift`, `Bitkit/Services/VssStoreIdProvider.swift`, `Bitkit/Services/RNBackupClient.swift`, `Bitkit/Services/BackupFieldMigration.swift`, `Bitkit/Services/MigrationsService.swift`.
- Sheet enum `SheetID.backup`; data `BackupConfig(view:)`, item `BackupSheetItem`; opened via `SheetViewModel.showSheet(.backup, data:)`, rendered in `Bitkit/MainNavView.swift`. Route `Route.dataBackups`, `.reset`. Timed: `Bitkit/Managers/TimedSheets/BackupTimedSheet.swift`. State: `AppViewModel.backupVerified`, `backupIgnoreTimestamp` (`@AppStorage`).
- Restore orchestration: `AppScene.restoreWalletBackupAndStart`, `restoreVssBackup`, `restoreFromMostRecentBackup`.

## How to drive it
- e2e `bitkit-e2e-tests/test/specs/backup.e2e.ts`, describe `@backup @ios_nightly`: `@backup_1` ("Can backup metadata, widget, settings and restore them"): fund 1 BTC with `receiveOnchainFunds({expectHighBalanceWarning:true})`, tag an activity, switch currency to GBP, add a Price widget, `getSeed()` (Settings -> Security -> `BackupWallet` -> `TapToReveal` -> read `SeedContainer`), `waitForBackup()` (Security -> `BackupSettings` -> wait `AllSynced`, retry up to 60 s), `restoreWallet(seed)`, then asserts `£` symbol (`MoneyFiatSymbol` in `TotalBalance`), `PriceWidget`, and `Tag-testtag-delete`. Needs funds (`ensureLocalFunds`), Electrum (`initElectrum`), an `E2E_BUILD` app and a reachable VSS server (backend choice per CI shard: could not determine from the spec).
- `bitkit-e2e-tests/test/specs/settings.e2e.ts` `@settings_07` ("Can show backup and validate it", `@settings @ios_nightly`): `ResetAndRestore`, `NavigationBack`, `BackupWallet`, `TapToReveal`, read seed, `ContinueShowMnemonic`, click `Word-<w>` in order, `ContinueConfirmMnemonic`, four `OK` taps.
- Migration, `bitkit-e2e-tests/test/specs/migration.e2e.ts` (describe "Wallet migration", no `@ios_*` tag; separate migration workflow: nightly, dispatch, `release-*` PRs, `BACKEND=regtest`; docs `bitkit-e2e-tests/docs/migration-tests.md`): `@migration_native_restore`, `@migration_native_upgrade` (previous native release from `PREVIOUS_NATIVE_APP_PATH`, via `test/helpers/native-migration.ts`), `@migration_rn_restore`, `@migration_rn_upgrade` (RN 1.1.6; iOS RN restore needs `RN_MNEMONIC`/`RN_BALANCE` prepared on Android by `@migration_setup_*`), extended `@migration_3` (passphrase), `@migration_4` (legacy p2pkh sweep) behind `MIGRATION_EXTENDED=true`.
- Journeys: none dedicated. `journeys/onchain-receive/restore-recent-receive-stays-silent.xml` exercises restore only.
- Unit tests: `BitkitTests/BackupServiceTests.swift`, `BackupFieldMigrationTests.swift`, `PaykitBackupStateTrackingTests.swift`, `PaykitPaymentStateBackupTests.swift`, `HwActivityTagBackupTests.swift`, `WidgetsBackupConverterTests.swift`, `RNMigrationCleanupTests.swift`, `RNMigrationAddressTypeTests.swift`, `LdkMigration.swift`.

## What proves it
- Backup done: `AllSynced` displayed on `BackupScrollView`; status rows show a relative time instead of "Required"/"Never".
- Phrase flow: `SeedContainer` text has 12 or 24 words; after the final `OK` the sheet closes and the backup suggestion card no longer shows (`backupVerified`).
- Restore: restored wallet shows same currency symbol, widgets, activity tags, balances (`@backup_1`, `expectMigrationBalances`, `verifyNativeHistory`).
- Migration: text "MIGRATING" displayed (RN upgrade), then `TotalBalance-primary` with matching savings/spending, `Tag-<x>-delete`, a received Lightning payment.

## Not covered by tests
- Passphrase wallets in the backup sheet (`BackupPassphrase`, `BackupConfirmPassphrase`): `@settings_07` and `@backup_1` use wallets without a passphrase; only RN `@migration_3` (extended, off by default) uses one.
- Timed backup prompt conditions (24 h snooze, balance > 0), `BackupIntro` "Later", 24-word display.
- Backup failure toast, per-category retry button, `LIGHTNING_CONNECTIONS`/`BLOCKTANK` content, VSS outage during restore, `WalletRestoreError` retry (see `onboarding.md`).
- RN remote backup vs VSS timestamp choice, `rewriteMigratedBackups`, pending-restore retry on foreground: unit coverage only for `BackupServiceTests` (one test) and field migration.
- Migration sweep path on iOS (`withSweep` is always false in `handleMigrationFlow`).

## Gotchas
- `AllSynced` exists only in `E2E_BUILD`/`E2E=true` builds (`Env.isE2E`); normal builds never show it.
- `getSeed()` (e2e) closes the sheet by swiping it down, never reaching `BackupSuccess`; the sheet's `onDismiss` then calls `app.ignoreBackup()` (`MainNavView.swift`), so `backupVerified` stays false. `native-migration.ts` comments that reading the seed marks backup complete; that is true for the 24 h reminder snooze only (inferred from code, not run).
- A restore sets `app.backupVerified = true` (`WalletRestoreSuccess`), so restored wallets do not get the reminder.
- Backups are paused while `isRestoring`/`isWiping`; restore replays can leave `required` status until `scheduleFullBackup` runs after start.
- RN iOS migration cases cannot be driven with Appium; iOS RN restore depends on wallets created on Android, and does not assert tags (`verifyTags: !driver.isIOS`).
- Native-restore tests need a strict simulator keychain reset (`resetBootedIOSKeychain({strict:true})`), else onboarding does not show.
- Migration docs: baselines pinned in `bitkit-e2e-tests/config/migration-baselines.json`; native iOS baseline artifact is a simulator `.app`.
