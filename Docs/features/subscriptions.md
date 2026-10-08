# Subscriptions (Paykit recurring payments)

Scope: creating and proposing a recurring subscription, reviewing/accepting/canceling one, the Subscriptions overview and detail screens, and local "payment due" reminder notifications. One-time requests and the Payments tab: see `payment-requests.md`.

## What it does
- Payer side: an incoming recurring proposal appears under PROPOSALS, can open automatically in the Review and Subscribe sheet, and is accepted with a swipe (`SwipeButton`). If the first period is due on acceptance the same sheet continues into an embedded Send flow (`SubscriptionSheetItem.Route.payment`), otherwise "Subscribed" success.
- Creator side: build a subscription (amount, frequency day/week/month/year, name, description, custom icon), choose a linked contact, optionally set proposal expiry, then propose. Proposals are capped at 1,000 UTF-8 bytes on the wire (`PaykitSubscriptionProposal.maximumMessageBytes`); longer ones throw `subscriptionTooLong` ("shorten the subscription content").
- Overview sections: PROPOSALS, ACTIVE, EXPIRED, CREATED plus a metrics row (monthly cost, active count, created count). A canceled subscription stays under ACTIVE (or CREATED) until its paid-through date, then moves to EXPIRED (`subscriptionSections`).
- Detail: status, frequency, renewal/expiry date, payments list; footer Cancel (payer) or Delete (creator), More Info when metadata has description or benefits. Cancel/Delete only when `recurrence.endsAt == nil` and the subscription is active (or a visible proposal for the creator) (`PaykitSubscription.canCancel`).
- Unsupported terms (payment deadline, unsupported unit, no usable endpoint) show an explanatory line and no Subscribe control (`isProposalActionable`).
- Reminders: local `UNCalendarNotificationTrigger` notifications (UTC wall-clock components), title "Subscription Payment Due", body "Open Bitkit to review a subscription payment." Scheduled by `PaykitSubscriptionNotificationScheduler` (max 32 pending, only for accepted payer subscriptions with no deadline and a supported unit). Disabling notifications removes them. Tapping stores a `PaykitSubscriptionNotificationTarget` and opens the due period (`AppDelegate`, `handlePendingPaykitSubscriptionNotification` in `Bitkit/AppScene.swift`).

## How a user reaches it
- Drawer `HeaderMenu` → `DrawerSubscriptions` (item hidden when Paykit UI is off) → `SubscriptionsScreen`, tabs `Tab-overview` / `Tab-payments`.
- Create: `SubscriptionCreate` → sheet `CreateSubscription` (`SubscriptionEditAmount` → amount step `SubscriptionAmount` reusing `PaymentRequestAmountField`/`PaymentRequestAmountContinue`; `SubscriptionName`, `SubscriptionDescription`, `Tab-day|week|month|year`, `SubscriptionIconPicker`) → `SubscriptionChooseRecipient` → `SubscriptionRecipient` (`SubscriptionContact<pubkey>`, `SubscriptionRecipientFilter`, `SubscriptionExpiration` menu) → `SubscriptionPropose` → `SubscriptionProposalSent`.
- Review: row `SubscriptionRow-<paymentRequestId>` under PROPOSALS → review sheet (provider card shows `SubscriptionCounterparty`; no sheet-level screen id found) → swipe → Send flow or success. A proposal also opens automatically via the incoming-item dispatcher (`subscriptionProposalForPresentation`).
- Detail: any non-proposal row → `Route.subscriptionDetail(id)` (no screen identifier found in code). Cancel/Delete open the `.cancel` sheet route with a swipe.
- Reminder tap: system notification (`bitkit_action = paykit_subscription_due`) → app opens the due period's payment (needs unlock).
- Dev only: Settings → Advanced → `DevSettings` → `SubscriptionClockOffset` menu, items `SubscriptionClockOffset-<0|1|7|30|31|62|365>` (debug builds only, `SubscriptionClock.isAvailable = Env.isDebug`; `DevSettings` row shows when `showDevSettings`, default `Env.isDebug`).

## Code
- Views: `Bitkit/Views/Subscriptions/SubscriptionsView.swift` (`SubscriptionsView`, `SubscriptionRow`, `SubscriptionDetailView`, `SubscriptionSheet`, `SubscriptionSuccessView`, `SubscriptionSheetItem`), `Bitkit/Views/Subscriptions/CreateSubscriptionView.swift` (`CreateSubscriptionView`, `SubscriptionAmountView`, `SubscriptionRecipientView`, `SubscriptionProposalSentView`), `Bitkit/Views/Wallets/Send/InitialSubscriptionPaymentProgress.swift`, `Bitkit/Views/PaymentRequests/CreatePaymentRequestView.swift` (shared `PaykitRecipientPicker`, `PaymentRequestAmountView`).
- Routes: `SheetID.subscription` with `SubscriptionSheetItem.Route` = `create, createAmount, createRecipient, proposalSent, review, success, details, cancel, payment(SendRoute)`; `Route.subscriptions(showPayments:)`, `Route.subscriptionDetail(id)` (`Bitkit/ViewModels/NavigationViewModel.swift`, `Bitkit/MainNavView.swift`).
- Model and state: `Bitkit/Services/PaykitSubscription.swift` (`PaykitSubscription`, recurrence, `PaykitSubscriptionStateStore` in Keychain key `paykitSubscriptionState`, `PaykitSubscriptionNotificationScheduler`, `PaykitSubscriptionNotificationIdentifier` prefix `paykit-subscription-`, `PaykitSubscriptionTimestamp`), `Bitkit/Services/PaykitSubscriptionProposal.swift`, manager methods `proposeSubscription/accept/cancel/synchronizeSubscriptionNotifications` in `Bitkit/Services/PaykitPaymentRequestService.swift`, `Bitkit/Utilities/SubscriptionClock.swift`.
- Notification plumbing: `Bitkit/BitkitApp.swift` (`PaykitSubscriptionNotificationTarget`, target store, `AppDelegate` response handler), `Bitkit/MainNavView.swift` (re-sync on `settings.enableNotifications`), `Bitkit/Views/Settings/DevSettingsView.swift`.

## How to drive it
- Setup: two linked Bitkit instances (creator + payer) with Paykit UI on, regtest `bitkit-docker`, payer funded above 5,000 sats (`E2E_BUILD`, see `journeys/README.md`). The `journeys/subscriptions/` folder has no README; preconditions are in each journey description.
- `journeys/subscriptions/create-and-propose.xml` ("Create And Propose Subscription"), `review-and-subscribe.xml` ("Review And Subscribe"), `cancel-and-delete.xml` ("Cancel And Delete Subscription"), `payments-tab.xml` ("Subscriptions Payments Tab"), `fixed-onchain-destination.xml` (linked regtest issuer, two periods, uses the Dev Settings clock offset), `cancellation-during-confirmation.xml` (issuer cancels while payer confirmation is open).
- Related: `journeys/payment-requests/delete-contact-with-active-subscription.xml`, `journeys/payment-requests/payment-deadline-history.xml` (subscription history with expired/unsupported deadlines, needs a controlled shared-runtime peer).
- Manual, not journeys: `journeys/paykit-clock-changes.md` (timezone/DST changes, device clock moved backward before a reminder, tapping a due reminder during contact preparation or at cold launch, reminder with unpreparable payment; also connection-loss recovery with `ProfileRetry`/`ProfileLoading`, see `profile-pubky.md`). Needs a disposable device or isolated clock; not a journey capability.
- E2E: none (`bitkit-e2e-tests/test/specs/` has no subscription spec).
- Unit tests: `BitkitTests/PaykitPaymentRequestServiceTests.swift` (subscription lifecycle, sections, notification scheduler incl. `testTravelAndDaylightSavingChangesPreserveUTCBillingReminders`, clock offset), `PaykitSubscriptionProposalTests.swift`, `SubscriptionClockTests.swift`, `PaykitPaymentProofServiceTests.swift`, `PaykitPaymentStateBackupTests.swift`.

## What proves it
- Propose: `SubscriptionProposalSent` with headline "Sent Proposal", contact and 5,000 sats row; creator CREATED row subtitle "Proposal sent" (not "Proposal queued").
- Accept: "Subscribed" confirmation; row moves PROPOSALS → ACTIVE; detail STATUS "Active", RENEWS one month ahead (no year); PAYMENTS section lists the payment only if one was made.
- Cancel: detail still "Active" with timing cell "EXPIRES" at paid-through date, no Cancel button; creator copy remains under CREATED.
- Delete: pending proposal with no payments leaves CREATED.
- Payments tab: badge on `Tab-payments`, `PaymentRequestsScreen`, `PaymentRequestRequestPayment`.
- Reminder: notification title "Subscription Payment Due"; (unit tests assert pending request identifiers and trigger components).

## Not covered by tests
- No E2E spec. Journeys are not run in CI and the iOS corpus "has not been run end to end".
- Reminder delivery and tap handling on a real device/simulator: only unit tests and the manual clock-changes doc; no journey step asserts a delivered notification.
- Frequencies other than monthly, `SubscriptionExpiration` menu choices, custom icon upload (PhotosPicker), subscriptions with `endsAt` (no Cancel), `More Info`/`.details` sheet beyond a mention in journeys, `SubscriptionSuccessView` Close, the embedded payment failure (`showInitialPaymentFailure`) path: no journey step found.
- `BitkitUITests/` has no subscription coverage.

## Gotchas
- `create-and-propose.xml` notes: the description is a `NoteTextEditor`, so `type-text --element-ref` is refused; tap it and use `type-text --text`. The sent headline wraps "Sent" over "Proposal".
- The amount step reuses the `PaymentRequest*` identifier prefix on purpose (matches Android).
- `SubscriptionRow-<paymentRequestId>` matches Android; `PaymentRequestRow-…` rows on the Payments tab add the billing period on iOS only.
- The "Automatically pay this subscription" toggle from the design handoff is unbuilt on both platforms (`review-and-subscribe.xml`).
- Dev clock offset moves due periods, renewals, proposal visibility and reminders only; real time is kept for proposal start, acceptance, one-time requests and payments (`SubscriptionClock`). Scheduler fires at `period start - offset` and posts a catch-up alert for periods the jump made due.
- A canceled subscription's paid periods are retained until the paid-through date; contact deletion is blocked while a subscription is active.
- Reminders are local notifications, scheduled from the main app only; they depend on `settings.enableNotifications`, not on push registration (see `notifications.md`).
