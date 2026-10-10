# Deep links, URL schemes, quick actions

Scope: URLs handed to the app by the OS (custom schemes, payment URIs, Pubky links), how they are retained and routed, and the home-screen quick action. Payment handling after routing: `send.md`, `receive.md`, `lnurl.md`, `gift.md`; Pubky contact/profile screens: `contacts.md`, `profile-pubky.md`.

## What it does
- Registered URL schemes (`Bitkit/Info.plist` `CFBundleURLSchemes`): `bitkit`, `bitcoin`, `BITCOIN`, `lightning`, `LIGHTNING`, `lnurl`, `lnurlw`, `lnurlp`, `lnurlc`. No `pubkyauth` or `pubkyring` scheme is registered.
- Universal links: none found. `Bitkit/Bitkit.entitlements` has no associated-domains key and the code has no `onContinueUserActivity` / `NSUserActivityTypeBrowsingWeb`.
- Entry points (all end in `AppViewModel.retainDeepLink(url)`, which stores `pendingDeepLinkURL`):
  - `AppScene` `.onOpenURL`, `AppDelegate.application(_:open:)` and `SceneDelegate.scene(_:openURLContexts:)` / `scene(_:willConnectTo:)` (cold start URL kept in `savedDeepLinkURL`, forwarded in `sceneDidBecomeActive`) -> `DeepLinkRouter.shared.forward` -> `Notification.deepLinkReceived` -> `AppScene.handleDeepLinkNotification`; `AppScene.onAppear` also calls `DeepLinkRouter.shared.consume()`.
- Routing (`MainNavView.handlePendingDeepLink` -> `AppViewModel.routePendingDeepLinkIfReady` -> `MainNavView.handleDeepLink`). `MainNavView` only exists after the PIN check (`AppScene.existingWalletContent`), so a link opened while locked stays pending until unlock. Held until:
  - contact links: saved contacts are loaded (`isContactDeepLinkReady`);
  - everything that needs LDK (`AppViewModel.requiresLightningNode`): node `.running`. These skip the wait: `http(s)`, `bitkit://contact`, `bitkit://pubky-auth/setup`, SamRock/BTCPay setup URLs, `bitcoin:` URIs, bolt11 (`lnbc`/`lntb`) invoices, `bitkit://gift-*`, Pubky auth protocol URLs.
- `handleDeepLink` branches:
  1. `http`/`https` -> `UIApplication.open` (used by the home-screen news widget; no payment handling).
  2. `bitkit://contact?pubky=<key>` (`PubkyContactLink`; exactly one `pubky` query item, no path/fragment/user) -> only when Paykit UI is active (otherwise silently ignored); invalid key -> error toast; valid -> `scannerManager.handleScan(key, .main)` -> `resolvePubkyRoute`: own key -> `Route.profile`, saved contact -> `Route.contactDetail`, else `Route.addContact`.
  3. Anything else -> `app.handleScannedData(url.absoluteString)` (same code path as the QR scanner): BIP21 `bitcoin:` (with optional `lightning=` param), `lightning:` bolt11, `lnurl*` (pay, withdraw, channel, auth), node URI (`.nodeId`), gift (`bitkit://gift-<code>`, `SheetID.gift`), SamRock/BTCPay setup (`SheetID.btcpayConnection`), Pubky auth. On success `PaymentNavigationHelper.openPaymentSheet` (send sheet or Quickpay) unless the URL is a SamRock or Pubky auth URL. Errors -> toast `other__qr_error_header` / `other__qr_error_text`.
  - Pubky auth from the OS: only `bitkit://pubky-auth/setup?...` (normalised to `pubkyauth://signin_grant`) is accepted; raw or `lightning:`/`lnurl*:`-prefixed pubkyauth/signup URLs throw `ScanHandlingError.pubkyAuthRequest`. Needs `PaykitFeatureFlags.isUIEnabled`. Opens `SheetID.pubkyAuthApproval` (watch-only consent, ids `PubkyAuthWatchOnlyConsent`, `PubkyAuthWatchOnlyCancel`); a bad request shows toast `PubkyAuthInvalidRequestToast`.
- Quick action: static Home Screen shortcut `Recovery` (`UIApplicationShortcutItems` in `Info.plist`) -> `SceneDelegate.handleQuickAction` -> `Notification.quickActionSelected` -> `AppScene.handleQuickAction` sets `showRecoveryScreen = true` (`Bitkit/Views/Recovery/`). Any other shortcut type is ignored.
- Internal-only: `bitkit://accent-tap` is a text-link marker in `Bitkit/Styles/TextStyle.swift`, not an external route.

## How a user reaches it
- No in-app path. A link is opened from Safari, another app, a QR scanned by the camera app, or `xcrun simctl openurl <device> "<uri>"`. The quick action is a long-press on the app icon. Safari test page for `lightning:` links: GitHub Pages deployed from `bitkit-e2e-tests/tools/ln-invoice-link/index.html`.
- Result screens/ids: Add Contact / Contact Detail / Profile (`contacts.md`, `profile-pubky.md`), `PubkyAuthWatchOnlyConsent`, send sheet (`send.md`), `InvalidAddressToast` (duplicated BIP21 or Paykit UI off for pubky auth).

## Code
- `Bitkit/SceneDelegate.swift` (`DeepLinkRouter`, `SceneDelegate`), `Bitkit/BitkitApp.swift` (`AppDelegate.open`, `Notification.Name.deepLinkReceived/quickActionSelected`), `Bitkit/AppScene.swift` (`.onOpenURL`, `handleDeepLinkNotification`, `handleQuickAction`), `Bitkit/MainNavView.swift` (`handleDeepLink`, `handlePendingDeepLink`, `pubkyContactPublicKeyForRouting`, `prepareAndRoutePendingDeepLink`), `Bitkit/ViewModels/AppViewModel.swift` (`pendingDeepLinkURL`, `retainDeepLink`, `routePendingDeepLinkIfReady`, `requiresLightningNode`, `handleScannedData`, `handlePubkyAuthApproval`).
- `Bitkit/Models/PubkyContactLink.swift`, `Bitkit/Models/PubkyAuthRequest.swift`, `Bitkit/Services/SamRockService.swift`, `Bitkit/Utilities/PaymentNavigationHelper.swift`, `Bitkit/Extensions/String+Utilities.swift` (`removingLightningSchemes`), `Bitkit/ViewModels/NavigationViewModel.swift` (`resolvePubkyRoute`).
- Routes/sheets reached: `Route.profile`, `.contactDetail`, `.addContact`; `SheetID.send`, `.pubkyAuthApproval`, `.btcpayConnection`, `.gift`, `.lnurlAuth`, `.lnurlWithdraw`. There is no `bitkit://screen/...` or sheet router.

## How to drive it
- Journeys: `journeys/deeplinks/pubky-contact.xml` ("pubky contact deeplink": unsaved key -> Add Contact prefilled; saved key -> Contact Detail; own key -> Profile; terminate then open saved key -> PIN screen first, then Contact Detail once; `bitkit://contact?pubky=invalid` -> nothing opens). Needs Paykit enabled, Pubky profile, one saved contact, PIN on. `journeys/pubky-auth/open-watch-only-link.xml` ("open watch-only auth link"): terminated app, `bitkit://pubky-auth/setup?...x-bitkit-claim=watch-only-account-v1` -> consent screen, Cancel; `x-bitkit-claim=unsupported-v1` -> `PubkyAuthInvalidRequestToast`. Needs `E2E_BUILD`, onboarded wallet, Pubky profile. Both use `xcrun simctl openurl`.
- Not ported: `journeys/README.md` "Not ported" lists Android `deeplinks/screen-deeplink.xml` and `sheet-deeplink.xml` (`bitkit://screen/...`, dev-mode gate, cold-start replay); iOS has no screen/sheet router.
- e2e: none. `bitkit-e2e-tests/test` has no `openurl`/deep-link call; send/lnurl specs feed payment strings through the in-app scanner (`ScanPrompt`, `QRInput`), not the OS. Workflow `bitkit-e2e-tests/.github/workflows/deploy-ln-invoice-link.yml` (on push to `main` touching `tools/ln-invoice-link/**`, or manual dispatch) publishes the Safari test page to GitHub Pages; it is not a test run.
- Unit tests: `BitkitTests/SceneDelegateTests.swift` (scene forwards `bitkit://pubky-auth/setup` URL to `DeepLinkRouter` and `.deepLinkReceived`), `PubkyAuthURLSchemeTests.swift` (unique `bitkit` scheme, URL retained through startup/restoration/PIN gates, consent routed exactly once, non-node links release without LDK), `PubkyContactLinkTests.swift`, `SamRockSetupRequestTests.swift`, `Bip21UtilsTests.swift`, `PaymentNavigationHelperTests.swift`.

## What proves it
- Contact link: Add Contact with the key prefilled, Contact Detail, or Profile as in the journey; for an invalid key no contact, payment or auth screen opens (error toast per code, journey only asserts nothing opens). After PIN unlock the target opens once.
- Watch-only link: `PubkyAuthWatchOnlyConsent` visible, then gone after `PubkyAuthWatchOnlyCancel`; invalid claim: `PubkyAuthInvalidRequestToast` and no consent screen.

## Not covered by tests
- No journey/e2e opens a `bitcoin:`, `lightning:`, `lnurl*:`, `bitkit://gift-*` or SamRock URL through the OS, nor an `http(s)` link, nor the Recovery quick action; cold-start retention for payment URIs and the node-running wait for LDK-dependent links are only unit-tested in part (`PubkyAuthURLSchemeTests` covers non-node links and pubky auth).
- Duplicate delivery of one URL through `.onOpenURL`, `AppDelegate.open` and `SceneDelegate` is not tested; whether iOS invokes more than one of them for the same open could not be determined.
- "Pubky callbacks" named in `journeys/README.md` capabilities: no callback URL handler beyond the above was found in code.
- Link-opening when Paykit UI is off (contact link silently ignored) has a unit test (`testDisabledPaykitIgnoresContactLinks`) but no journey.

## Gotchas
- `journeys/README.md` states only `bitkit://pubky-auth/setup`, `bitkit://contact?pubky=`, web URLs, Pubky callbacks and payment URIs route; anything else, e.g. `bitkit://screen/...`, is dropped or shown as a payment decode error.
- Simulator may show an "Open in Bitkit?" prompt for `xcrun simctl openurl`; the pubky-auth journey says to tap Open.
- The scheme list includes uppercase `BITCOIN`/`LIGHTNING` entries; scheme comparisons in code lowercase the value.
- A bolt11 link does not wait for the node, but the send sheet then handles an unsynced node itself (see `AppViewModel.handleScannedData` comments).
- Deep links are consumed once (`pendingDeepLinkURL = nil` before the handler runs); a failure is not retried.
