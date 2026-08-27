# CJIT notification journeys

Verify that a CJIT payment surfaces exactly one notification, and that a regular (non-CJIT) channel
opening is never reported as a received payment.

## Adapted from Android — read this first

The Android suite asserts notification **copy** that iOS does not produce. `BitkitNotification/NotificationService.swift`
maps a Blocktank push type to fixed title/body pairs and never formats an amount:

| Blocktank type | iOS title | iOS body |
| --- | --- | --- |
| `cjitPaymentArrived` | Incoming Payment | Open Bitkit now to receive your payment |
| `incomingHtlc` | Incoming Payment | Open Bitkit now to receive your payment |
| `orderPaymentConfirmed` | Spending Balance Ready | Open Bitkit to start paying anyone, anywhere. |
| `mutualClose` | Spending Balance Expired | Open Bitkit to move funds from spending to savings |
| `wakeToTimeout` | Payment Pending | Open Bitkit to process pending payment |

Consequences for the port:

- **Android issue #1 (missing thousands separators) has no iOS counterpart.** iOS never puts an
  amount in the notification, so there is no formatting to assert. Those actions are dropped rather
  than rewritten into something the app was never meant to do.
- **Android issue #2 (double notification) does port**, as "exactly one notification". iOS has no
  foreground service and no `WakeNodeWorker`; the Notification Service Extension is the only poster,
  so the duplicate would have to come from a duplicate push.
- **Android issue #3 (channel open reported as a payment) ports directly** and is the strongest of
  the three: `orderPaymentConfirmed` must render as "Spending Balance Ready", never "Incoming Payment".
- `cjit-foreground-service-notification.xml` becomes `cjit-background-notification.xml` — iOS has no
  foreground service, so the equivalent state is simply "app backgrounded".

## Preconditions
- **A physical device, not the simulator.** These journeys need a real APNs round trip: the app must
  hold a device token Blocktank can push to, and the NSE must decrypt a real Blocktank payload.
  Run them on the self-hosted macOS runner used by `.github/workflows/ai-device-tests.yml`.
  `test-push-server/` can drive a hand-built push at a known device token when you need to exercise
  the NSE without the LSP.
- Onboarded regtest wallet connected to the LSP, with notifications authorized and
  "Get paid when Bitkit is closed" enabled in Settings → Notifications.
- A funded CJIT entry ready to pay, and no Lightning channel open yet for the CJIT journeys.

## Inspecting notifications on iOS

There is no `dumpsys notification`. Two options, in order of preference:

1. **Read the extension's own log.** `NotificationService` logs through `os_log`, unlike the main app
   (which writes log files into the app group). Stream it while the push lands:
   ```bash
   xcrun simctl spawn <device> log stream --predicate 'eventMessage CONTAINS "🔔"'   # simulator
   log stream --predicate 'eventMessage CONTAINS "🔔"'                                # attached device host
   ```
   The `🔔 Configured notification: type=…, title=…` line names the type and title it posted.
2. **Snapshot Notification Center.** Swipe down from the top of the screen and take a
   `xcodebuildmcp simulator snapshot-ui`, then count the Bitkit entries and read their text.

## Identifiers used
- In-app toast: `SpendingBalanceReadyToast`.
- Received payment sheet: `ReceivedTransactionButton`.
