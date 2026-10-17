# Contacts

Pubky contact list: add, view, edit, delete, import from a Pubky follow list, pay a contact, contact activity, contact payment sharing, `bitkit://contact` links.

## What it does
- Contacts are Paykit contact records of the signed-in Pubky identity (`ContactsManager`), sorted by name, with profiles resolved in batches in the background.
- Add: key entered/pasted/scanned in `AddContactSheet`, then `AddContactView` fetches the profile and offers Save (and Pay when the contact has a payable public endpoint). Save lands on `.contactSaved` (detail with Delete instead of Edit).
- Detail: Pay, Activity, Copy, Share, Edit or Delete, tags, links. Edit uses the shared profile form (`Bitkit/Components/ProfileEditFormView.swift`) and has Delete there too.
- Delete is refused with toast `contacts__delete_active_subscription` while a subscription is active (see `subscriptions.md`).
- Import: after adopting a Pubky Ring identity (see `profile-pubky.md`), `ContactsManager.destinationAfterAuthentication` loads the follow list (own key excluded) and opens `.contactImportOverview`, or `.payContacts` if nothing was found. Import All or Select saves the chosen contacts, then `navigation.path = [.payContacts]`.
- Pay Contacts (`PayContactsView`, Continue `PayContactsContinue`) enables contact payment sharing (`ContactPaymentsService.setEnabled`) and then opens `.profile`.
- Sharing toggle: Settings > General row `ContactPaymentsToggle`, shown only when Paykit UI is active and the user is authenticated (`GeneralSettingsView.swift:105`).
- Pay a contact: `ContactPay` opens the Receive sheet `.requestOrPay(publicKey:)` when an eligible payment-request target exists (see `payment-requests.md`), otherwise `PaymentNavigationHelper.openPrivateContactPayment` opens the Send sheet. Send sheet also has Recipient > Contact (`SendContactSelectView`).
- Contact activity: `ContactActivityView` lists activities tagged to the contact.
- Deep link `bitkit://contact?pubky=<key>` and scanned/pasted keys route via `resolvePubkyRoute`: own key > `.profile`, saved > `.contactDetail`, else `.addContact`.

## How a user reaches it
- Home `HeaderMenu` > `DrawerContacts` > `ContactsDestinationView` (`ContactsIdentityLoading` spinner while the identity lookup runs). It then shows `ProfileDestinationView` (saved identity not signed in), `ContactsIntro` (id; button `ContactsIntro-button`; shown while `hasSeenContactsIntro` is false and no contacts), `ContactsListView` (authenticated), `PubkyChoiceView` (profile intro seen) or `ProfileIntro`.
- `ContactsIntro-button` on an authenticated profile sets `shouldOpenAddContactSheet` and opens the list with the add sheet open (`ContactsIntroView.openContacts`).
- List: `ContactsAddButton`, `ContactsEmptyAddButton` (empty list), `ContactsMyProfile`, rows `Contact_<publicKey>` (key as stored, e2e uses the `pubky...` prefixed form), `ContactsRetry` (load error). Search field has only the accessibility label `common__search`.
- Add sheet: `AddContactPubkyField`, `AddContactPaste`, `AddContactScanQR`, `AddContactAdd` (disabled until valid). Inline errors from `resolveAddContactValidation`.
- Add screen: `AddContactRetrievingTitle`, `AddContactSave`, `AddContactPay`, `AddContactRetry` or `AddContactDiscard` (non-retryable: invalid, own, existing key).
- Detail: `ContactViewName`, `ContactViewNotes`, `ContactPay`, `ContactActivity`, `ContactCopy`, `ContactShare`, `ContactEdit` or `ContactDelete`, `ContactAddTag`, `ContactViewTagsHeader`, `ContactRetry`. Toasts `ContactDeletedToast`, `ContactUpdatedToast`.
- Edit: `ProfileEditName`, `ProfileEditBio`, `ProfileEditAddLink`, `ProfileEditSave`, `ProfileEditCancel`, `ProfileEditDelete`, `EditContactAvatar`. Delete confirm is an alert ("Yes, Delete").
- Contact activity rows: `ContactActivity-<index>` where index counts date-group headers too (first activity is `-1`).
- Import: `ContactImportOverviewProfile`, `ContactImportOverviewSummary`, `ContactImportOverviewSelect`, `ContactImportOverviewImportAll`, then `ContactImportSelect_<publicKey>`, `ContactImportSelectAll`, `ContactImportSelectNone`, `ContactImportSelectContinue`.
- Send sheet: `RecipientContact` > rows `SendContact-<publicKey>`.

## Code
- Views: `Bitkit/Views/Contacts/` (`ContactsDestinationView`, `ContactsIntroView`, `ContactsListView`, `AddContactSheet`, `AddContactView`, `ContactDetailView`, `EditContactView`, `ContactActivityView`, `ContactImportOverviewView`, `ContactImportSelectView`), `Bitkit/Views/Profile/PayContactsView.swift`, `Bitkit/Views/Wallets/Send/SendContactSelectView.swift`, `Bitkit/Views/Wallets/Activity/AssignActivityContactView.swift` (see `activity.md`).
- Routes (`Bitkit/ViewModels/NavigationViewModel.swift`): `.contacts`, `.contactsIntro`, `.contactDetail`, `.contactSaved`, `.contactActivity`, `.contactImportOverview`, `.contactImportSelect`, `.addContact`, `.editContact`, `.payContacts`, `.assignActivityContact`. Mapped in `Bitkit/MainNavView.swift:531-640`; with Paykit UI off `.contacts`/`.contactsIntro` show `ComingSoonScreen`, the other routes show `paykitDisabledRedirectView`.
- Sheets: `SheetID.receive` with `ReceiveConfig(view: .requestOrPay)`, `SheetID.send` with `SendConfig`, route `SendRoute.contact`.
- Logic: `Bitkit/Managers/ContactsManager.swift`, `Bitkit/Services/ContactPaymentsService.swift`, `PrivatePaykitService*.swift`, `PublicPaykitService.swift`, `Bitkit/Utilities/PaymentNavigationHelper.swift`, `Bitkit/Models/PubkyContactLink.swift`, `PubkyPublicKeyFormat.swift`.
- Flag: `Bitkit/FeatureFlags/PaykitFeatureFlags.swift` (`FEATURE_PAYKIT_UI_DISABLED` build flag, `paykitUiEnabled` default).
- UI-test fixture: `Bitkit/Utilities/Testing/ContactImportUITestFixture.swift` (DEBUG, launch arg `-contact-import-ui-test`, `BitkitApp.swift:187`).

## How to drive it
- Journeys (`journeys/contacts/`): `contacts-entry-points.xml` ("contacts entry points"), `delete-newly-saved-contact.xml` ("delete newly saved contact"), `import-all-contacts.xml` ("import all prepared contacts"), `import-selected-contacts.xml` ("import selected prepared contacts"), `contact-payment-sharing.xml` ("contact payment sharing stays disabled"); `journeys/deeplinks/pubky-contact.xml` ("pubky contact deeplink", `xcrun simctl openurl`). Related in `journeys/pubky-profile/`: `contact-import-after-leaving.xml`, `contacts-list-loading.xml`. Fault-injection checks are manual per `journeys/contacts/README.md`.
- Preconditions: Paykit UI enabled E2E build, disposable Pubky identity; import journeys need a Ring identity with known follows (e.g. 62) not yet saved; deep link journey needs PIN on.
- E2E (`bitkit-e2e-tests/test/specs/pubky-profile.e2e.ts`, describe tags `@pubky @pubky_profile @pubky_staging, @staging`): `@pubky_profile_1` (entry gating), `@pubky_profile_3` (invalid/own key, scan/paste routes, add and delete two contacts), `@pubky_profile_4` (edit contact on wallet B leaves wallet A profile). Helpers: `test/helpers/profile.ts` (`addContact`, `deleteContact`, `updateContactProfile`, `verifyContactDetails`, `verifyAddContactRoute`), fixtures `STAGING_TEST_CONTACTS`.
- `bitkit-e2e-tests/test/specs/paykit.e2e.ts` `@paykit_1` (describe `@pubky @paykit @pubky_staging, @staging`): funds 50 000 sats, creates profile, routes unsaved Paykit key to Add Contact, saves `STAGING_PAYKIT_CONTACTS[0]`, pays 10 000 sats on-chain via `ContactPay`, checks contact activity. Needs `BACKEND=regtest` staging Pubky; no `@ios_gate`/`@ios_nightly` tag. Manual charter: `bitkit-e2e-tests/docs/public-contact-payments-manual-qa.md`.
- Unit/UI: `BitkitUITests/ContactImportUITests.swift` (4 tests on the fixture), `BitkitTests/ContactsManagerTests.swift`, `ContactsListViewTests.swift`, `ContactPaymentsServiceTests.swift`, `PaykitContactLifecycleTests.swift`, `PubkyContactLinkTests.swift`, `ProfileDestinationViewTests.swift`, `PaymentNavigationHelperTests.swift`.

## What proves it
- Add/save: `ContactViewName`, `ContactPay`, `ContactActivity`, `ContactCopy`, `ContactShare`, `ContactDelete`, `ContactAddTag` visible (`profile.ts addContact`); row `Contact_<pubkey>` in the list.
- Delete: `ContactDeletedToast`, Contacts shows `ContactsAddButton`, row gone, deleted screen not in Back history.
- Edit: `ContactUpdatedToast`, `ContactEdit` visible; `verifyContactDetails` reads `ContactView*` ids.
- Import: friend count in `ContactImportOverviewSummary`; after import `PayContactsContinue` visible; Contacts lists the selected rows only.
- Sharing off: `ContactPaymentsToggle` off and stays off after reopening Settings.
- Contact pay: Send amount screen (`SendAmount`), then `SendSuccess`; contact activity has "Sent to" row.
- Deep link: `AddContactSave` flow for unsaved key, Contact Detail for saved, Profile for own, PIN screen first when locked, nothing for invalid.

## Not covered by tests
- Journeys/e2e skip: tags add/remove on a contact, links display, Share sheet, Copy toast, contact search, `ContactsRetry`, `ContactRetry`, `AddContactRetry`, duplicate-add (commented out in `pubky-profile.e2e.ts`), Pay from `AddContactPay` with Lightning, Lightning/BOLT11 contact pay (`paykit.e2e.ts` pays on-chain only).
- Not run by any journey or spec: Settings sharing toggle ON path, cleanup failures, deletion with active subscription (only `journeys/payment-requests/delete-contact-with-active-subscription.xml`, see `payment-requests.md`), `AssignActivityContactView`.
- Import fault cases (failed batch, cancel, self-follow, retry) have unit tests in `ContactsManagerTests` / `PaykitContactLifecycleTests` and manual notes only; Import-with-Ring stays manual in e2e (comment in `pubky-profile.e2e.ts`).

## Gotchas
- Everything gated by `PaykitFeatureFlags.isUIAvailable && paykitUiEnabled`; off hides the Subscriptions drawer item, shows Coming Soon on Contacts and ignores contact links (`PubkyContactLinkTests`).
- `Contact_<key>` ids and `ContactImportSelect_<key>` use the key as stored by the app; Android uses different Ring row tags (`journeys/README.md` table).
- Contact deep link waits for Pubky init and contacts load, and for PIN unlock (`MainNavView.swift:93-100`, `PubkyContactLinkTests`).
- Leaving the import routes discards the pending preview (`shouldDiscardPendingImport`); an import that finishes later saves but must not open Pay Contacts (`ContactImportUITests`).
- Continue on Pay Contacts waits for public setup, not private linking with every contact (`journeys/contacts/README.md`).
- Own key is excluded from import discovery (`ContactsManager.swift:955`).
- iOS toasts live in a separate window; e2e waits for toast to disappear before the next drawer tap (`profile.ts`).
- Re-adding a deleted contact is the only action that restores the private connection; label edits do not unblock (`PaykitContactLifecycleTests`).
