# App update prompts

Scope: startup check of the published iOS build number, the dismissible "update available" sheet, and the blocking "critical update" screen. No journey and no e2e spec cover it; only a unit test of the timed-sheet eligibility.

## What it does
- `AppUpdateService.checkForAppUpdate()` fetches `Env.updaterUrl` (`Bitkit/Constants/Env.swift`) and decodes `{"platforms": {"ios": {buildNumber, version, url, notes?, critical}}}`. If `platforms.ios.buildNumber` > the app's `CFBundleVersion` (as `Int`), it sets `availableUpdate`; otherwise sets it to nil. Fetch/decode errors are only logged.
- URL: production `https://github.com/synonymdev/bitkit/releases/download/updater/release.json`; `Env.isE2E` builds use `https://github.com/synonymdev/bitkit-e2e-tests/releases/download/updater/release.json`. The repo file `bitkit-e2e-tests/updater/release.json` has `buildNumber: 0` and `critical: false` for ios and android, so an E2E build never sees an update (that this file is what is served at the release URL is unverified).
- Non-critical update: `AppUpdateTimedSheet` (priority medium, registered in `TimedSheetManager.setup`) opens `AppUpdateSheet` (`SheetID.appUpdate`) on a primary screen after a 2 s settle delay. Eligibility (`AppUpdateTimedSheet.shouldShow`): not E2E, an update exists, `critical == false`, and more than 12 h (`ASK_INTERVAL`) since `appUpdateIgnoreTimestamp`. Sheet buttons: Continue opens `Env.appStoreUrl`; Cancel just closes. Continue, Cancel and any dismiss call `app.ignoreAppUpdate()` (stores now in `appUpdateIgnoreTimestamp`). The timed sheet is one-time per session (removed from the queue once shown).
- Critical update: `AppScene.mainContent` shows `AppUpdateScreen` instead of the wallet when `availableUpdate?.critical == true` and `!Env.isDebug`. Screen has no back/menu; one button opens the App Store.
- `AppUpdateService.shared.$availableUpdate` change calls `TimedSheetManager.shared.reevaluate()` so a late response can still show the sheet.

## How a user reaches it
- Not user-initiated. The check runs once from `AppViewModel.init` (with `checkGeoStatus`), i.e. at app start. Sheet appears on the home screen (or onboarding root; the update prompt is the only timed sheet eligible without a wallet, per comment in `TimedSheetManager`). Critical screen replaces all content on launch.
- Ids: sheet `AppUpdateSheet`, `AppUpdateSheetImage`, `AppUpdateSheetDescription`, buttons `AppUpdateSheetContinue`, `AppUpdateSheetCancel` (derived from `SheetIntro` testID `AppUpdateSheet`). Critical screen `CriticalUpdate`, button `CriticalUpdate-button` (`OnboardingView` testID rule).

## Code
- `Bitkit/Services/AppUpdateService.swift` (`AppUpdateInfo`, `AppUpdateRelease`, `availableUpdate`), `Bitkit/Managers/TimedSheets/AppUpdateTimedSheet.swift`, `Bitkit/Managers/TimedSheets/TimedSheetManager.swift`.
- `Bitkit/Views/Sheets/AppUpdateSheet.swift` (`AppUpdateSheetItem`), `Bitkit/Views/AppUpdateScreen.swift`, `Bitkit/AppScene.swift` (`hasCriticalUpdate`, `.sheet(item: $sheets.appUpdateSheetItem ...)`, `onReceive($availableUpdate)`), `Bitkit/ViewModels/AppViewModel.swift` (`appUpdateIgnoreTimestamp`, `ignoreAppUpdate()`, reset to 0 on app reset), `Bitkit/ViewModels/SheetViewModel.swift` (`appUpdateSheetItem`).
- Sheet enum case: `SheetID.appUpdate`. No `Route`.

## How to drive it
- Journeys: none (`ls journeys/` has no app-update suite). e2e: none (`grep` for `AppUpdate`, `CriticalUpdate`, `updater` in `bitkit-e2e-tests/test` finds nothing).
- Unit test: `BitkitTests/AppUpdateTimedSheetTests.swift` (XCTest on the pure `AppUpdateTimedSheet.shouldShow`): shown for non-critical past interval; hidden for no update, critical, within interval, E2E; the interval boundary is exclusive.
- Manual only: not possible on an `E2E_BUILD` (sheet suppressed, URL points to the e2e release file) and critical screen is also suppressed in Debug builds; a Release/TestFlight build with a reachable release JSON having a higher `buildNumber` would be needed (no tooling for that found in either repo).

## What proves it
- Sheet: `AppUpdateSheet` displayed; Continue opens the App Store URL; reopening the app within 12 h shows no sheet.
- Critical: `CriticalUpdate` displayed and the wallet UI is not reachable. (Both are expectations from code; no test asserts them.)

## Not covered by tests
- The network fetch and decode in `AppUpdateService`, build-number comparison, the `AppScene` critical gate, `AppUpdateSheet` buttons and `ignoreAppUpdate()` wiring, the `reevaluate()` path, behaviour when the release JSON lacks an `ios` key (logs an error only).

## Gotchas
- Check happens only at `AppViewModel` init, not on foreground; an app left running does not re-check.
- Comparison uses the build number (`CFBundleVersion`), not the marketing version string.
- `hasCriticalUpdate` is disabled in Debug (`!Env.isDebug`); `shouldShow` is disabled in E2E, via different flags.
- The timed sheet competes with other timed sheets in the queue (backup, high balance, notifications, quickpay); queue is ordered by priority and the first eligible one is shown, then removed.
