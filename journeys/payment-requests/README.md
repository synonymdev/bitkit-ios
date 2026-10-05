# Payment Request journeys

These journeys cover incoming Paykit Payment Requests from a linked issuer and requests that Bitkit can receive but cannot open.
The issuer contract and exact accepted/rejected data live in
[`Docs/paykit-issuer-interoperability.md`](../../Docs/paykit-issuer-interoperability.md) and
[`BitkitTests/Fixtures/paykit-issuer-interoperability.json`](../../BitkitTests/Fixtures/paykit-issuer-interoperability.json).
The resolution-failure journey is ported alongside Android's matching `requested-resolution-failure.xml` journey.

## Issuer interoperability

### Setup

Run Bitkit against regtest with Paykit UI enabled. Authenticate a Pubky identity, save the fixture issuer as a contact, link its server receiver on `bitkit/server`, and give the wallet enough on-chain balance to pay 100,000 sats. The fixture issuer must be able to publish a Paykit endpoint and send a one-time Payment Request to that linked peer. A Bitkit app acting as the issuer exposes `bitkit/wallet` instead, so a Bitkit-to-Bitkit run uses that negotiated path throughout.

The accepted journey uses:

- Payment Request ID: `71300000-0000-4000-8000-000000000001`
- Asset: `btc`
- Amount: `0.001`
- Accepted identifier: `btc-regtest-p2wpkh`
- Endpoint payload: `{"value":"bcrt1qissuerfixture"}`, replacing the placeholder address with a valid current receive address from the issuer

Rejected fixture shapes stay in unit tests because Bitkit intentionally does not present requests that fail the contract gate.

### Reference evidence

The source wallet-leg run completed this path on regtest on 2026-08-22: Bitkit presented the incoming request, opened the on-chain payment, broadcast it, and confirmed transaction
`cc85df0e24b54be353a57700429d144b35264c1af97f3de41c503dc52f1e4792` at height `77318`.

That run established the issuer shapes captured by the fixture: lowercase `btc`, `btc-regtest-p2wpkh`, and a JSON object endpoint payload with a non-empty string `value`. The exact Debug binary SHA was not recorded, so the canonical fixture tests lock the same production gates on the current code.

## Resolution-failure contract

- Parse-time rejection emits a warning with `category=parse`, a stable reason code, and only the
  redacted counterparty. It does not include the request id, amount, note, endpoint identifier, or
  endpoint payload.
- Open-time rejection emits a warning with `category=resolution` or `category=presentation`, a
  stable reason code, and only the redacted counterparty.
- An explicit Pay action tries immediately and fourteen more times at two-second intervals. After
  the fifteenth failure, Bitkit shows an error toast with localized keys `wallet__payment_request`
  and `wallet__payment_request_unavailable`, then leaves the request available for another attempt.
- If the request expires during an explicit presentation attempt, Bitkit logs
  `category=presentation reason=request_expired` and shows `PaymentRequestExpiredToast` with the
  localized `wallet__payment_request_expired` message.
- Automatic presentation uses the same initial retries, then continues every 120 seconds without
  showing terminal feedback.
- RecoveryRequired or Linking is reported as pending immediately. An explicit Pay action shows
  `PaymentRequestWaitingForDetailsToast`, releases presentation ownership, and leaves Pay and
  Dismiss available while the supported SDK recovery continues in the background.

The failure reason vocabulary is:

- Parse: `missing_local_role`, `outgoing_request`, `unsupported_local_role`, `missing_terms`,
  `recurring_request`, `unsupported_asset`, `unsupported_payment_deadline`, `invalid_amount`, `amount_out_of_range`,
  `no_supported_endpoint`, `invalid_expiration`, `expired`.
- Resolution: `no_supported_endpoint`, `endpoint_not_payable`, `payment_details_pending`,
  `resolution_failed`.
- Presentation: `invalid_payment_target`, `payment_target_not_routable`, `request_expired`.

`outgoing_request` and `non_actionable_state` are expected filtering of outgoing or completed
records, so they do not emit incoming-rejection warnings. `unsupported_local_role` identifies an
unknown role and emits a privacy-safe warning with only the redacted counterparty.

### Setup

Use a controlled Paykit peer linked to a saved contact. Seed one proposed incoming request with a
known id, lowercase `btc`, a positive amount, a future expiration, and a supported accepted endpoint
identifier. Keep the peer's payment list empty or unsupported long enough for all fifteen explicit
resolution attempts. Do not use a malformed request for the UI journey because parse-time rejection
correctly prevents it from entering the presentation queue.

## Request summary

`request-summary.xml` is ported alongside Android's matching journey.

### Setup

Use a second Bitkit instance as the requester instead of the fixture issuer: both instances are
authenticated Pubky identities, saved as each other's contacts and linked on receiver path
`bitkit/wallet`, and the payer holds enough balance to pay 21,000 sats.

## Definite pre-broadcast retry

`definite-pre-broadcast-retry.xml` uses the linked fixture issuer and the local regtest LNURL server.
Configure its LNURL-pay metadata endpoint normally, but make its invoice callback fail the first
request and succeed after it is switched back to the healthy response. Do not republish the Paykit
payment list between attempts. This makes the first send fail before Lightning dispatch and proves
that the same private payment details can be opened and paid on retry.

### Hardware authorization failure

Injecting a failure in the final Paykit authorization check is not a journey capability. Check this
manually with the linked issuer and a funded regtest hardware wallet: allow preparation to succeed,
then fail `linkedPeers()` during the authorization check before broadcast. Restore the peer without
publishing a new payment list and retry from the hardware signing screen. The same unpaid request
must be prepared and authorized again before it broadcasts. If a broadcast may have begun, retain
the consumed details and started proof until the payment is reconciled.

## Contact Request Or Pay

`contact-request-or-pay.xml` is ported alongside Android's matching journey.

### Setup

Use the same two-instance setup as the request summary, and start from the payer's Contact Detail
screen, opened through the `bitkit://contact?pubky=` deeplink. Its timing step assumes the payer has
been running for about a minute: right after launch, the Paykit session restore and link refresh hold
the SDK and can push the Pay step well past the budget.

## Identifiers used

- Pending-request bell: `PaymentRequestsBell`.
- Incoming sheet: `PaymentRequestsSheet`.
- Screen: `PaymentRequestsScreen`.
- Detail screen: `PaymentRequestDetailScreen`.
- Detail amount and status: `PaymentRequestDetailsAmount`, `PaymentRequestDetailsStatus`.
- Request row: `PaymentRequestRow-<payment-request-id>-one-time`; use the complete identifier because `wait-for-ui` does not support prefix matching.
- Pay action: `PaymentRequestPay-<payment-request-id>`.
- Dismiss action: `PaymentRequestDismiss-<payment-request-id>`.
- Payment confirmation: `PaymentRequestConfirm`.
- Confirmation summary: `PaymentRequestFrom`, `PaymentRequestFor`.
- Confirmation invoice note: `PaymentRequestInvoiceNote`.
- Confirmation details: `SendConfirmToggleDetails`.
- Saved-contact recipient: `ReviewContactRecipient`.
- Contact Detail pay action: `ContactPay`.
- Request or Pay sheet: `RequestOrPaySheet` (its Pay and Request buttons carry no identifier; find them by label).
- Payment Request amount screen: `PaymentRequestAmount`.
- Terminal feedback: `PaymentRequestUnavailableToast`.
- Expiration feedback: `PaymentRequestExpiredToast`.
- Private-link recovery feedback: `PaymentRequestWaitingForDetailsToast`.
- Send failure: `SendFailure` and retry action `Retry`.
- Swipe control: `GRAB`.

`delete-and-readd-contact.xml` uses two Bitkit instances to verify that deleting a contact revokes private requests across restart and that explicitly adding the contact again restores a fresh private connection. It does not send funds.

`delete-contact-with-active-subscription.xml` requires an accepted open-ended payer subscription. It verifies that deletion explains why the contact must stay saved until the subscription ends, then that canceling, deleting, and readding does not revive it. No new payment is sent. Both contact-deletion journeys are mirrored on iOS and Android.

## Payment deadline history

`payment-deadline-history.xml` covers rc56 requests with actual-payment deadlines.
Bitkit keeps their lifecycle and paid-period history, and subscription cancellation,
but does not accept them, offer payments, or schedule payment reminders. The journey
requires a controlled rc56 peer to prepare the accepted and paid records; repository
tests cover these states without sending funds. On iOS, payment-history rows show notes
or dates rather than lifecycle labels. On Android, unpaid history rows show lifecycle
labels, while paid rows show subscription names, notes, or dates. Active subscriptions
are opened from Overview. The journeys therefore record each fixture's payment request id, check
its full row identifier, and include the required back and tab transitions. The accepted
subscription must have no end date so cancellation is available. The proposal review
must explain that its payment details are unsupported and offer no Subscribe control.
