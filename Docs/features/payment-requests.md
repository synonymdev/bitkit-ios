# Payment requests (Paykit)

Scope: one-time Paykit Payment Requests between linked Pubky contacts (create/send, incoming review and pay, history, detail), the Paykit services behind them, issuer interoperability and the Pubky marketplace wallet leg. Recurring subscriptions: see `subscriptions.md`.

## What it does
- Outgoing: pick an eligible saved contact, amount, note (max 256 chars) and expiry (hour/day/week/month), then send a one-time BTC request (`PaykitPaymentRequestManager.propose`). Completion says "Sent" or "Queued" by `deliveryStatus`.
- Incoming: the manager polls the private inbox and shared request state (every 10 s foregrounded, slower maintenance rounds; `PaykitPaymentRequestPollingSchedule` in `Bitkit/AppScene.swift`). A fresh request opens the Send confirmation sheet automatically (id `PaymentRequestConfirm`) unless another sheet is open; the swipe control `GRAB` stays disabled until validation and wallet preparation finish.
- Bell, sheet, list, detail: pending requests show the header bell, a "Payment Requests" sheet (3 newest, Dismiss/Pay), the Payments tab list and a detail screen.
- Actionable gate (contract in `Docs/paykit-issuer-interoperability.md`): lowercase `btc`, positive amount, one-time, local role payer, proposed/accepted state, valid future proposal expiry, absolute UTC `paymentDeadline` not passed, at least one supported endpoint identifier for the current network. Failures log `category=parse|resolution|presentation` plus a reason code and are not presented.
- Retry rules: explicit Pay retries now plus 14 times at 2 s, then toast `PaymentRequestUnavailableToast`; expiry gives `PaymentRequestExpiredToast`; link recovery gives `PaymentRequestWaitingForDetailsToast`; automatic presentation retries every 120 s with no toast (`PaykitPaymentRequestManager`, `Bitkit/AppScene.swift`).
- Paykit stack: public endpoints (`PublicPaykitService`), private per-contact endpoints and invoices (`PrivatePaykitService`), payment proofs (`PaykitPaymentProofService`), received-payment contact attribution (`PaykitReceivedPaymentContacts`). Paykit UI is on by default (`PaykitFeatureFlags.uiEnabledByDefault = true`).

## How a user reaches it
Precondition: Paykit UI on, a Pubky profile, contact payments on (Settings → General `ContactPaymentsToggle`), contacts saved and linked.
- Incoming: header bell `PaymentRequestsBell` (only when pending requests exist) → sheet `PaymentRequestsSheet` → row `PaymentRequestRow-<paymentRequestId>-one-time` (detail) or `PaymentRequestPay-<id>` / `PaymentRequestDismiss-<id>`; `PaymentRequestsSeeAll` → Subscriptions screen on the Payments tab (`Tab-payments`, list `PaymentRequestsScreen`).
- Same list: drawer `DrawerSubscriptions` → `SubscriptionsScreen` → `Tab-payments`. Detail screen `PaymentRequestDetailScreen` with `PaymentRequestDetailsAmount`, `PaymentRequestDetailsStatus`, `PaymentRequestDetailsPay`, `PaymentRequestAddTag`; back via `NavigationBack`.
- Create, three entries (each appears only when `eligibleTargets` is non-empty):
  - Payments tab footer `PaymentRequestRequestPayment` → Receive sheet at recipient step (`PaymentRequestRecipient`).
  - Receive QR screen button `ReceiveRequestPayment`.
  - Receive edit screen button `PaymentRequestSendButton` (needs amount > 0; carries amount and note into the draft).
  - Contact Detail `ContactPay` → `RequestOrPaySheet` (Pay/Request buttons carry no identifier) → Request → `PaymentRequestAmount`.
- Recipient step ids: `PaymentRequestRecipientFilter`, `PaymentRequestRecipientPaste`, `PaymentRequestContact<pubkey>` (dynamic), `PaymentRequestRecipientUnavailable`. Amount step: `PaymentRequestAmountField`, `PaymentRequestAmountUnit`, `PaymentRequestAmountContinue`. Details step: `PaymentRequestSend`. Done: `PaymentRequestSent`.
- Confirmation (Send sheet with an incoming request): `PaymentRequestConfirm`, `PaymentRequestFrom`, `PaymentRequestFor`, `SendConfirmToggleDetails`, `PaymentRequestInvoiceNote`, `ReviewContactRecipient`.
- Row ids are built from the billing period start for recurring rows (`-<ISO start>`), `-one-time` otherwise (`rowAccessibilityIdentifier`).

## Code
- Views: `Bitkit/Views/PaymentRequests/PaymentRequestsView.swift` (`PaymentRequestsSheet`, `PaymentRequestsView`, `PaymentRequestDetailView`, `PaymentRequestCard`, `PaymentRequestDisplay`), `Bitkit/Views/PaymentRequests/CreatePaymentRequestView.swift` (`RequestOrPayView`, `PaymentRequestRecipientView`, `PaykitRecipientPicker`, `PaymentRequestAmountView`, `PaymentRequestDetailsView`, `PaymentRequestSentView`), `Bitkit/Components/Header.swift` (bell), `Bitkit/Views/Wallets/Send/SendConfirmationView.swift` and `SendSheet.swift` (incoming-request confirmation).
- Routes: `SheetID.paymentRequests`; `Route.subscriptions(showPayments:)`, `Route.paymentRequestDetail(id)` (`Bitkit/ViewModels/NavigationViewModel.swift`, rendered in `Bitkit/MainNavView.swift`); `ReceiveRoute.requestOrPay/paymentRequestRecipient/paymentRequestAmount/paymentRequestDetails/paymentRequestSent` (`Bitkit/Views/Wallets/Receive/ReceiveSheet.swift`).
- Manager and presentation: `Bitkit/Services/PaykitPaymentRequestService.swift` (`PaykitPaymentRequestManager`, `PaykitPaymentRequestService`, `PaykitPaymentRequest`), `Bitkit/AppScene.swift` (`IncomingPaykitPaymentRequestPreparation`, presentation dispatcher, toasts, polling).
- Services: `Bitkit/Services/PublicPaykitService.swift`, `PrivatePaykitService.swift` (+`+Contacts/+Endpoints/+Invoices/+Payments/+State/+Backup/+Errors/+Models`), `PrivatePaykitAddressReservationStore.swift`, `PaykitPaymentProofService.swift`, `PaykitReceivedPaymentContacts.swift`, `PaykitIssuerInterop.swift`, `Bitkit/Models/PaykitPaymentStateBackup.swift`, `Bitkit/Utilities/PaykitPaymentActivity.swift`, `Bitkit/FeatureFlags/PaykitFeatureFlags.swift`.
- Docs: `Docs/paykit-issuer-interoperability.md`. Marketplace claims: `Docs/pubky-auth-companion-claims.md`, `Bitkit/Views/Sheets/PubkyAuthApproval/PubkyAuthApprovalSheet.swift`, `Bitkit/Models/PubkyAuthRequest.swift`, `Bitkit/Services/WatchOnlyAccountService.swift` (auth screens: see `profile-pubky.md`).

## How to drive it
- Common: `journeys/README.md` build with `E2E_BUILD`, regtest `bitkit-docker`, fund wallet via borrowed `../bitkit-android/lsp`. Most payment-request journeys need two linked Bitkit instances or a controlled Paykit issuer fixture (App ID `paykit-server`; Bitkit uses `bitkit`); see `journeys/payment-requests/README.md`.
- `journeys/payment-requests/`: `issuer-interoperability.xml` (fixture request `71300000-0000-4000-8000-000000000001`, 0.001 btc, `btc-regtest-p2wpkh`), `automatic-presentation.xml`, `request-summary.xml`, `contact-request-or-pay.xml`, `requested-resolution-failure.xml` (needs a peer with no endpoint for 35 s), `accepted-device-ownership.xml` (two installs, same identity, `lnurl-server` in `bitkit-docker`), `definite-pre-broadcast-retry.xml`, `absolute-payment-deadline.xml`, `payment-deadline-history.xml`, `delete-and-readd-contact.xml`, `delete-contact-with-active-subscription.xml` (see `contacts.md`).
- `journeys/pubky-marketplace/`: `wallet-leg.xml` (two simulators, external Paykit Server fixture, build flags `E2E_BACKEND=local E2E_NETWORK=regtest E2E_HOMESERVER_PUBKY=<pubky>`, Fulcrum on `tcp://127.0.0.1:60001`), `paykit-only-approval.xml`, `paykit-reconnect.xml` (consent/cancel only, no relay).
- Manual only (README prose, not journeys): hardware broadcast recovery, hardware authorization failure, `journeys/paykit-clock-changes.md` (device clock and connectivity fault injection; reminder parts in `subscriptions.md`).
- E2E: `bitkit-e2e-tests/test/specs/paykit.e2e.ts`, `@paykit_1` (describe `@pubky @paykit @pubky_staging, @staging`, uses `ciIt`): public on-chain endpoint payment to a saved staging contact, not payment requests. CI: iOS runs it in the `@pubky_staging` shard (not `@ios_gate`/`@ios_nightly`); needs staging backend contacts in `bitkit-e2e-tests/test/helpers/fixtures.ts` (`STAGING_PAYKIT_CONTACTS`).
- Unit tests: `BitkitTests/PaykitPaymentRequestServiceTests.swift` (largest), `PaykitIssuerInteropTests.swift` + `BitkitTests/Fixtures/paykit-issuer-interoperability.json`, `PaykitPaymentProofServiceTests.swift`, `PaykitPaymentRequestPollingScheduleTests.swift`, `PrivatePaykitServiceTests.swift`, `PublicPaykitServiceTests.swift`, `PaykitReceivedPaymentContactsTests.swift`, `PaykitPaymentStateBackupTests.swift`, `PaykitPaymentActivityTests.swift`.

## What proves it
- Create: `PaymentRequestSent` with title "Sent" (or "Queued") and the request card.
- Incoming: `PaymentRequestConfirm` with sender (`PaymentRequestFrom`), note (`PaymentRequestFor`, "Not specified" if none), amount; swipe `GRAB`, then `SendSuccess`; row no longer offers Pay/Dismiss and the bell disappears when none pending.
- Detail: `PaymentRequestDetailsStatus` "Waiting for payment" for a proposed incoming request; `PaymentRequestDetailsAmount` shows the sats.
- Failures: `PaymentRequestUnavailableToast` (title "Payment Request", "The payment request is no longer available."), `SendFailure` + `Retry`.
- Marketplace: `ActivityAmount`/`ActivityTxDetails`, `StatusConfirmed`, seller `ActivitySavings` increase; fixture side confirms purchase.
- E2E `paykit_1`: contact activity shows text "Sent to" and amount `10 000`.

## Not covered by tests
- No E2E spec for creating, receiving, paying or dismissing payment requests, nor for history/detail screens; journeys are agent-driven and not run in CI (`journeys/README.md`: "has not been run end to end" on iOS).
- Journeys needing a controlled issuer, shared-runtime peer or LNURL failure injection have no repo-provided fixture; availability could not be determined.
- Create-request tags, expiry picker choices (hour/day/month), queued (offline) delivery and the `ReceiveRequestPayment` / `PaymentRequestSendButton` entries: no journey step found.
- Rejection of a request via Dismiss on the detail screen, recoveryRequired/linking states, per-reason parse rejections: unit tests only (service tests), no UI journey.
- No UI tests in `BitkitUITests/` cover Paykit.

## Gotchas
- `docs/payment-requests.md` named in the brief does not exist. The filesystem is case-insensitive: `docs/` and `Docs/` are the same directory, tracked by git as `Docs/`.
- Identifier differences vs Android (`journeys/README.md`): `PaymentRequestDetailScreen` (Android `PaymentRequestDetailsScreen`); iOS row ids append the billing period; `wait-for-ui` needs the complete id (no prefix match).
- Closing a preparing confirmation suppresses automatic reopening for the identity's app session (not persisted); the request stays pending and manually reopenable.
- Contact `Pay` timing: right after launch the SDK is held by session restore and link refresh; journey assumes the app has run about a minute. `ContactPay` waits up to 2 s for `eligibleTarget` before choosing Pay-only vs Request-or-Pay.
- Acceptance is saved before the remote operation and in wallet backups; only the accepting install may retry a one-time payment (`accepted-device-ownership.xml`).
- Paykit UI can be switched off at runtime (Dev Settings `PaykitUiToggle`); routes then render `paykitDisabledRedirectView` and published endpoints are cleaned up. `FEATURE_PAYKIT_UI_DISABLED` compile flag is read in `PaykitFeatureFlags` but I found no definition in the project files.
- Marketplace payout detection depends on periodic sync with the seller app active; backgrounding invalidates the run (`journeys/pubky-marketplace/README.md`).
- Hardware wallets: broadcast-uncertain outcomes must keep the started proof; documented as manual-only.
- E2E specs share Android and iOS; `paykit.e2e.ts` waits up to 60 s for the send sheet and retaps `ContactPay` once after 8 s.
