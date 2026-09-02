# Payment-request journeys

These journeys cover incoming Paykit Payment Requests that Bitkit can receive but cannot open.

## Failure contract

- Parse-time rejection emits a warning with `category=parse`, a stable reason code, and only the
  redacted counterparty. It does not include the request id, amount, note, endpoint identifier, or
  endpoint payload.
- Open-time rejection emits a warning with `category=resolution` or `category=presentation`, a
  stable reason code, and only the redacted counterparty.
- An explicit Pay action tries immediately and fourteen more times at two-second intervals. After
  the fifteenth failure, Bitkit shows an error toast with localized keys `wallet__payment_request`
  and `wallet__payment_request_unavailable`, then leaves the request available for another attempt.
- Automatic presentation uses the same initial retries, then continues every 120 seconds without
  showing terminal feedback.

The failure reason vocabulary is:

- Parse: `missing_local_role`, `missing_terms`, `recurring_request`, `unsupported_asset`,
  `invalid_amount`, `amount_out_of_range`, `no_supported_endpoint`, `invalid_expiration`, `expired`.
- Resolution: `no_supported_endpoint`, `endpoint_not_payable`, `payment_details_pending`,
  `resolution_failed`.
- Presentation: `invalid_payment_target`, `payment_target_not_routable`.

`unsupported_local_role` and `non_actionable_state` are expected filtering of outgoing or completed
records, so they do not emit incoming-rejection warnings.

## Mandatory setup

Use a controlled Paykit peer linked to a saved contact. Seed one proposed incoming request with a
known id, lowercase `btc`, a positive amount, a future expiration, and a supported accepted endpoint
identifier. Keep the peer's payment list empty or unsupported long enough for all fifteen explicit
resolution attempts. Do not use a malformed request for the UI journey because parse-time rejection
correctly prevents it from entering the presentation queue.

## Identifiers used

- Screen: `PaymentRequestsScreen`.
- Request row: `PaymentRequestRow-<payment-request-id>`.
- Pay action: `PaymentRequestPay-<payment-request-id>`.
- Terminal feedback: `PaymentRequestUnavailableToast`.
