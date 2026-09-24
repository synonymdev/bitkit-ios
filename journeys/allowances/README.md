# Allowances journeys

Cover the Paykit allowance lifecycle between two Bitkit instances: the payer sets an allowance for a
contact, the payee accepts it, requests within the limits are paid without asking, a request above a
limit falls back to the normal Payment Request sheet, and either side ends it. The restart journey
pins the one rule that must never break: a payment interrupted mid-flight is never paid twice.

## Setup

Run Bitkit against regtest with Paykit UI enabled on two instances that have each other saved as
contacts and linked on receiver path `bitkit/wallet`, exactly as for
[`../subscriptions/README.md`](../subscriptions/README.md). One instance plays the payer (the one
that sets the allowance), the other the payee (the one that sends requests). Automatic payments go
over Lightning only, so the payer needs a spending balance above 50,000 sats with a usable channel,
and the payee needs receiving capacity; fund both through the staging LSP.

Allow notifications for Bitkit on the payer when it asks: the "Payment Executed" and "Limit
Reached" events post a local notification when they can, and fall back to an in-app toast that the
UI snapshot cannot see.

The journeys set $5 a payment and $50 a month, the second stop on each slider, and the cap journey
sets $5 a payment and $10 a month, the first monthly stop. Requests are one-time Payment Requests
created from the Payments tab of the payee, in the fiat unit. Dollar amounts on screen are converted
at the current rate, so a sats amount next to them will differ between runs.

## Reference evidence

The source run drove every journey on 2026-09-24 across two Android 16 emulators against the
staging regtest LSP, with Paykit built from pubky/paykit-rs#161, and the set, accept, auto-pay,
ask-above-limit and end flows again on two iOS simulators. A $2 and a $4 request were paid
about two seconds after arriving, a $20 request asked, the third $4 request on a $10 monthly cap
raised Limit Reached, ending the allowance from either side stopped automatic payments, and a payer
killed right after handing the payment to the node never paid twice after relaunch.

## Identifiers used

- Tab: `Tab-allowances`; empty state `AllowancesEmpty`; footer button `AllowanceAdd`
- Contact picker: `AllowanceContact-<displayName>`
- Set sheet: `SetAllowance`, sliders `AllowancePerPayment` and `AllowanceMonthly` with stops
  `AllowancePerPaymentStop-<index>` and `AllowanceMonthlyStop-<index>`, `AllowanceSummary`,
  `AllowanceSave`
- List row: `AllowanceRow-<allowanceId>` with its status line `AllowanceRowStatus`
- Review sheet (payee): `AllowanceReview`, `AllowanceCounterparty`, `AllowancePerPaymentValue`,
  `AllowanceMonthlyValue`, `AllowanceAccept`, `AllowanceDecline`
- Detail sheet: `AllowanceDetail`, `AllowancePaidSoFar`, `AllowanceDetailStatus`
- Payments tab: `Tab-payments`, `PaymentRequestRequestPayment`,
  `PaymentRequestRow-<paymentRequestId>-one-time` whose subtitle ends with "· Auto-paid" for an
  automatic payment
- Incoming request: `PaymentRequestsBell`, `PaymentRequestsSheet`

The review sheet on the payee opens on its own about a second after the proposal arrives; no tap is
needed to reach it. The file names, journey names and step prose match
[`bitkit-android/journeys/allowances`](https://github.com/synonymdev/bitkit-android/tree/master/journeys/allowances);
only the identifier annotations and the kill, relaunch and notification mechanics differ.
