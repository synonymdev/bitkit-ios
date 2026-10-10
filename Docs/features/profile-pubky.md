# Pubky profile and Pubky Auth

Scope: own Pubky profile (create, view, edit, delete, session restore), Pubky Ring identity choice, Pubky Auth approval (signup, ordinary, Paykit-only, watch-only consent), and the marketplace wallet leg. Contacts are in `contacts.md`; Paykit payment requests in `payment-requests.md`, subscriptions in `subscriptions.md`.

## What it does
- Gives the wallet a Pubky identity derived from the wallet seed (`PubkyService.derivePubkySecretKey`), or adopts a Pubky Ring identity read from the shared keychain group `pubky.shared` (`Bitkit/Utilities/SharedPubkyKeychain.swift`, `listRingIdentities()`).
- Profile: name, bio, links, tags, avatar, copyable pubky, QR code. Edit saves to the homeserver; Delete Profile wipes homeserver profile data (the pubky stays seed-derived).
- Disconnect (local sign-out) is shown only in the empty/failed-load state of Profile, and after a failed delete (`EditProfileView.disconnectAfterFailedDelete`).
- Cold start shows a cached name read-only (`ProfileCachedHeader`) while the session restores; restore retries are automatic (see `journeys/paykit-clock-changes.md`).
- Pubky Auth: the sheet approves `pubkyauth://` requests. Signup requests create the profile session. `bitkit://pubky-auth/setup` (OS link) is normalized to `pubkyauth://signin_grant` and needs an `x-bitkit-claim` (`paykit-access-v1`, `watch-only-account-v1`, or both dot-joined, `Bitkit/Models/PubkyAuthRequest.swift`). Watch-only claims first show a consent screen; approval shares an xpub, never spending keys (`docs/pubky-auth-companion-claims.md`).
- Marketplace leg: a seller grants Paykit access plus a watch-only account; a linked buyer pays the resulting request on regtest.

## How a user reaches it
- Home header `ProfileButton` (`Bitkit/Components/Header.swift`) -> `Header.profileDestination`: existing identity -> `.profile`; otherwise `ProfileIntro` (continue `ProfileIntro-button`, once) -> `.pubkyChoice`. Drawer: `HeaderMenu` -> `DrawerProfile` (`Bitkit/Components/DrawerView.swift`).
- Choice screen `Bitkit/Views/Profile/PubkyChoiceView.swift`: `PubkyChoiceCreate` (shown only with no Ring identities), or one row per Ring identity `PubkyChoiceRing_<bare z32 pubky>` with spinner `PubkyChoiceRingLookup_<pubky>` (dynamic ids). Tapping a Ring row adopts it, then goes to contact import overview or `PayContactsContinue`.
- Create: `CreateProfileUsername` (text), `CreateProfileAvatar`, `CreateProfileSave` (disabled for blank name; hidden behind keyboard until dismissed) -> `PayContactsContinue`. The iOS Pay Contacts screen has no toggle; Continue enables contact payments (`ContactPaymentsService.setEnabled(true...)`). Toggle later: General Settings `ContactPaymentsToggle`.
- View: `ProfileViewName`, `ProfileEdit`, `ProfileCopy` (toast `ProfilePubkyCopiedToast`), `ProfileShare`, `ProfileQRCode`, `ProfileAddTag`, links `ProfileLinkLabel_<i>`/`ProfileLinkValue_<i>`. Empty state: `ProfileRetry`, `ProfileEmptySignOut` (label "Disconnect"); loading `ProfileLoading`.
- Edit (`ProfileEdit` -> `.editProfile`): `ProfileEditName`, `ProfileEditLink_<i>`, `ProfileEditLinkRemove_<i>`, `ProfileEditAddTag`, `AddLinkLabel`/`AddLinkSave`, `AddTagInput`/`AddTagSave`, `ProfileEditCancel`, `ProfileEditSave` (toast `ProfileUpdatedToast`), `ProfileEditDelete` (scroll down) -> alert button "Yes, Delete" (no identifier) -> choice screen.
- Pubky Auth entry points: (a) OS link `xcrun simctl openurl <udid> "bitkit://pubky-auth/setup?caps=...&relay=...&secret=...&cid=...&cpk=...&x-bitkit-claim=..."`; (b) home Scan screen, paste or scan `pubkyauth://` or `pubkyring://signup` (`ScannerScreen`, `AppViewModel.handleScannedData` case `.pubkyAuth`). `lightning:`-prefixed forms are rejected.
- Sheet ids (`Bitkit/Views/Sheets/PubkyAuthApproval/PubkyAuthApprovalSheet.swift`): `PubkyAuthWatchOnlyConsent`, `PubkyAuthWatchOnlyApprove`, `PubkyAuthWatchOnlyCancel`, `PubkyAuthPaykitAccess`, `PubkyAuthAuthorize`, `PubkyAuthCancel`, `PubkyAuthOK`, `PubkyAuthRelayOrigin`, `PubkySignupHomeserver`; toast `PubkyAuthInvalidRequestToast`.

## Code
- Views: `Bitkit/Views/Profile/` (`ProfileView.swift` incl. `ProfileDestinationView`, `PubkyChoiceView`, `CreateProfileView`, `EditProfileView`, `ProfileIntro`, `PayContactsView`, `AddLinkSheet`, `AddProfileTagSheet`, `LinkSuggestionsSheet`, `TagSuggestionsSheet`), `Bitkit/Components/ProfileEditFormView.swift` (shared with contact edit), `Bitkit/Components/PubkyImage.swift`.
- Routes (`Bitkit/ViewModels/NavigationViewModel.swift`, rendered in `Bitkit/MainNavView.swift` ~L600): `.profile`, `.profileIntro`, `.pubkyChoice`, `.createProfile`, `.editProfile`, `.payContacts`. `.profile` shows `ComingSoonScreen` when `PaykitFeatureFlags.isUIEnabled` is false (default true; compile flag `FEATURE_PAYKIT_UI_DISABLED`).
- Sheet: `SheetID.pubkyAuthApproval` (`SheetViewModel.pubkyAuthApprovalSheetItem`), config `PubkyAuthApprovalConfig`.
- Managers/services: `Bitkit/Managers/PubkyProfileManager.swift` (`initialize`, `createIdentity`, `adoptRingIdentity`, `approveSignupAuth`, `saveProfile`, `deleteProfile`, `signOut`, `retrySessionRestoration`, `loadRingIdentityProfiles`), `Bitkit/Services/PubkyService.swift` (`approveAuthRequest`, `approveAuthWithCompanionClaim`, `signUp`, `signIn`, `publishPaykitProfile`, `deletePaykitProfile`; actor `PaykitSdkService`), `WatchOnlyAccountManager` (referenced by `approveAuthRequest`), `Bitkit/Utilities/SharedPubkyKeychain.swift`.
- Auth routing: `Bitkit/Models/PubkyAuthRequest.swift`; `AppViewModel.handlePubkyAuthApproval` (invalid -> toast, signup with stored identity -> "already signed in", no session or no local/Ring secret -> warning toast); retained links via `AppViewModel.retainDeepLink`/`routePendingDeepLinkIfReady` and `MainNavView.handleDeepLink`. `bitkit://pubky-auth/setup` does not need the Lightning node (`requiresLightningNode`). URL scheme `bitkit` in `Bitkit/Info.plist`.
- Local auth before authorize: PIN/biometrics via `resolvePubkyApprovalLocalAuthMode` (`AuthCheck` cover).

## How to drive it
- Journeys (all need an onboarded `E2E_BUILD`, Paykit UI on; simulator via `xcodebuildmcp`):
  - `journeys/profile/delete-profile.xml` ("profile deletion progress"; disposable identity; 62 imported contacts variant).
  - `journeys/profile/signup-create-profile.xml` ("create profile after signup"; staging.pubky.app browser signup, unfunded fresh wallet).
  - `journeys/pubky-profile/cached-profile-header.xml` ("cached profile header while loading").
  - `journeys/pubky-profile/ring-choice-rows.xml` ("pubky ring choice rows"; needs Pubky Ring on the same simulator, same Apple team, 2+ identities, no Bitkit identity).
  - `journeys/pubky-profile/contact-import-after-leaving.xml`, `contacts-list-loading.xml`: see `contacts.md`.
  - `journeys/pubky-auth/open-watch-only-link.xml` ("open watch-only auth link"; needs a Bitkit-generated identity; dummy request, cancels before export).
  - `journeys/pubky-marketplace/paykit-only-approval.xml` ("paykit only approval"), `paykit-reconnect.xml` ("paykit reconnect"), `wallet-leg.xml` ("pubky marketplace wallet leg"). Needs the external fixture in `journeys/pubky-marketplace/README.md`: Pubky testnet, Paykit Server, regtest bitcoind + Fulcrum at `tcp://127.0.0.1:60001`, two simulators built with `E2E_BUILD E2E_BACKEND=local E2E_NETWORK=regtest E2E_HOMESERVER_PUBKY=<pubky>`.
  - Manual only: `journeys/paykit-clock-changes.md` (device clock, timezone, offline recovery).
- E2E: `bitkit-e2e-tests/test/specs/pubky-profile.e2e.ts`, describe tags `@pubky @pubky_profile @pubky_staging, @staging`. Cases: `@pubky_profile_1` (entry points -> choice), `@pubky_profile_2` (create, edit, relaunch, restore from seed, remove link/tag, delete, recreate same pubky), `@pubky_profile_3`/`_4` (contacts, see `contacts.md`), `@pubky_profile_5` (home scanner `pubkyauth://direct_signup?hs=...` after profile). Run: `npm run e2e:ios -- --mochaOpts.grep "@pubky_profile_2"`. CI: `@pubky_staging` shard only (`BACKEND=regtest`, staging Homegate `homegate.staging.pubky.app`); no `@ios_gate`/`@ios_nightly`.
- Helpers: `bitkit-e2e-tests/test/helpers/profile.ts` (`createProfile`, `deleteProfile`, `updateMyProfile`, `verifyMyProfileDetails`, `openEditProfile`), `navigation.ts` (`openProfile`).
- QA fixture (not CI): `BACKEND=regtest ./scripts/qa-fixture.sh ios pubky|full` runs `bitkit-e2e-tests/test/qa-fixtures/qa-fixture.e2e.ts` + `test/helpers/qa-fixture.ts`; writes `artifacts/qa-fixture.json` and `qa-fixture.pubky`; env `QA_FIXTURE_PROFILE_NAME` (default "QA Wallet").
- Manual charters: `bitkit-e2e-tests/docs/pubky-profile-manual-e2e.md`, `bitkit-e2e-tests/docs/public-contact-payments-manual-qa.md` (contact side, see `contacts.md`). Avatar fixtures: `./scripts/push-fixture-media-to-devices.sh`.

## What proves it
- Create: `PayContactsContinue` shown, then `ProfileEdit`/`ProfileCopy`/`ProfileShare` and the uppercase name visible; pubky from `ProfileQRCode` equals the copied pubky and survives relaunch, seed restore and delete+recreate (`@pubky_profile_2`).
- Edit: toast `ProfileUpdatedToast`, `ProfileEdit` visible again. Delete: `PubkyChoiceCreate` visible; reopening Profile does not show the old profile.
- Cached header: `ProfileCachedHeader` + `ProfileCachedName` with edit/copy/share/QR/tag absent, then `ProfileViewName` replaces it.
- Ring rows: `PubkyChoiceRing_<pubky>` rows, lookup spinners gone, tapped row adopted, then `ContactImportOverviewProfile` or `PayContactsContinue`.
- Watch-only link: `PubkyAuthWatchOnlyConsent` visible, gone after `PubkyAuthWatchOnlyCancel`; unsupported claim -> `PubkyAuthInvalidRequestToast`, no consent screen.
- Authorize: `PubkyAuthOK`; Paykit-only shows `PubkyAuthPaykitAccess` and no `PubkyAuthWatchOnlyConsent`.
- Signup scan with existing profile: text "Already signed in", no `PubkyAuthAuthorize`, no `CreateProfileUsername` (`@pubky_profile_5`).
- Marketplace evidence table (snapshots and fixture state) is in `journeys/pubky-marketplace/README.md`; payment-side ids in `payment-requests.md`.
- Unit tests (`BitkitTests/`): `PubkyProfileManagerTests`, `PubkyChoiceViewTests`, `ProfileDestinationViewTests`, `PubkyAuthApprovalSheetTests`, `PubkyAuthRequestTests`, `PubkyAuthURLSchemeTests` (defers gated link, routes consent once), `SharedPubkyKeychainTests`, `WatchOnlyAccountServiceTests`, `PendingProfileSetupResumeTests`, `PubkyIdentityRepublishTests`, `PubkyImageCacheTests`, `PubkyModelTests`, `ProfileLinkRowTests`, `PaykitSdk*Tests`.

## Not covered by tests
- Successful Pubky Auth authorize (ordinary, Paykit-only, watch-only) end to end: journeys stop at consent/cancel; success only in `wallet-leg.xml` with the external fixture (not in CI).
- PIN/biometric gate before authorize (`AuthCheck`, `authorizeWithBiometrics`): no journey or e2e; unit coverage of mode choice only (`resolvePubkyApprovalLocalAuthMode`, could not confirm which test).
- Signup authorize: only `signup-create-profile.xml` (external browser, not in CI); `pubkyring://signup` and `PubkySignupHomeserver` not asserted anywhere.
- Ring adoption beyond row mechanics (no Ring in CI); Ring-secret-missing toast (`pubky_auth__use_ring`) and no-identity toast (`pubky_auth__no_identity`).
- Session expiry, offline restore, retry backoff, clock changes, identity switch races: manual (`journeys/profile/README.md`, `journeys/paykit-clock-changes.md`); unit tests only.
- Avatar upload (`CreateProfileAvatar`, `EditProfileAvatar`): no spec taps them. Link/tag suggestion sheets (`AddLinkSuggestions`, `AddTagSuggestions`): not asserted.
- `ProfileShare` content, `ProfileEmptySignOut` (Disconnect) and `disconnectAfterFailedDelete`: no test drives them. Delete-failure alert: none.
- `Header.profileDestination` branches for `initializationErrorMessage` / `cachedName`: unit tests only (could not determine which).

## Gotchas
- Paykit UI is on by default; `FEATURE_PAYKIT_UI_DISABLED` build makes `.profile` show Coming Soon and other routes redirect.
- e2e helper `createProfile({payContactsOption:false})` taps `PayContactsToggle`, which does not exist in iOS code (`PayContactsView` has only Continue). Default path is unaffected.
- `PubkyChoiceImport` was removed; the Create card is hidden whenever Ring identities exist (`PubkyChoiceView.showsCreateCard`). `journeys/README.md`: Android uses `PubkyChoiceIdentity` for the rows.
- "Yes, Delete" is matched by text (English only); the e2e helper retries on iOS because the alert click can precede hittability.
- A bare spinner right after launch is the Pubky initialization wait in `MainNavView`; a spinner under the "Profile" title with no name means no cached header. A warm network can finish loads before a snapshot: journeys report "already loaded/resolved/adopted" rather than fail.
- Ring identity profile lookups can take several seconds to give up; adoption disables all rows until done. Ring rows are tagged with the bare z32 key; Contacts rows use the `pubky`-prefixed key.
- Only `bitkit://pubky-auth/setup` is accepted as an OS link (needs query and claim); raw `pubkyauth://` is accepted only via the scanner. There is no screen/sheet deeplink router.
- Links delivered during startup, restoration or PIN entry are retained and presented only after the main UI is ready (`journeys/pubky-auth/README.md`).
- Staging dependency: profile creation calls Homegate (`homegate.staging.pubky.app`); the charter notes a 4xx blocks create-from-scratch. Toasts in e2e use `waitToDisappear` on iOS because they render in a separate window.
- Pubky keys are seed-derived: wipe+restore of the same seed gives the same pubky; the e2e spec asserts this.
- Keychain sharing with Ring needs the same Apple team; Bitkit cannot seed Ring records.
