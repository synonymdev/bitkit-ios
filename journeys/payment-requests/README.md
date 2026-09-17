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

The failure reason vocabulary is:

- Parse: `missing_local_role`, `outgoing_request`, `unsupported_local_role`, `missing_terms`,
  `recurring_request`, `unsupported_asset`, `invalid_amount`, `amount_out_of_range`,
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

## Identifiers used

- Pending-request bell: `PaymentRequestsBell`.
- Incoming sheet: `PaymentRequestsSheet`.
- Screen: `PaymentRequestsScreen`.
- Request row: `PaymentRequestRow-<payment-request-id>-<counterparty>-<receiver-path>-one-time`; construct the complete value from the fixture issuer public key and negotiated receiver path because `wait-for-ui` does not support prefix matching.
- Pay action: `PaymentRequestPay-<payment-request-id>`.
- Dismiss action: `PaymentRequestDismiss-<payment-request-id>`.
- Payment confirmation: `PaymentRequestConfirm`.
- Confirmation details: `SendConfirmToggleDetails`.
- Saved-contact recipient: `ReviewContactRecipient`.
- Terminal feedback: `PaymentRequestUnavailableToast`.
- Expiration feedback: `PaymentRequestExpiredToast`.
