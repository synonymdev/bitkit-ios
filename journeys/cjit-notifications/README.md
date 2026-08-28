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
  hold a device token Blocktank can push to, and the notification extension must decrypt a real
  Blocktank payload. Nothing runs this suite automatically, and that is not a gap to
  fill here — `ai-device-tests.yml` runs `TrezorBridgeDashboardUITests` on a simulator and is not a
  journey runner. Run these by hand against an attached device. `test-push-server/` can drive a hand-built push at a known device token when you need to exercise
  the extension without the LSP.
- Onboarded regtest wallet connected to the LSP, with notifications authorized and
  "Get paid when Bitkit is closed" enabled in Settings → Notifications.
- A funded CJIT entry ready to pay, and no Lightning channel open yet for the CJIT journeys.

## Inspecting notifications on iOS

There is no `dumpsys notification`. Two options, in order of preference:

1. **Read Notification Center on the device.** Swipe down from the top of the screen, then count the
   Bitkit entries and read their text. This is the supported assertion path.
   `xcodebuildmcp simulator snapshot-ui` does not apply — it drives a simulator, and this suite runs
   on hardware.
2. **The extension's own log, if you can get at it.** `NotificationService` logs through `os_log`
   (unlike the main app, which writes log files into the app group), at `.info` level, so any
   predicate needs `--level info` to see it — the `🔔 Configured notification: type=…, title=…` line
   names the type and title it posted. Note `/usr/bin/log stream` has no `--device` flag, so there is
   no verified one-liner for an attached device here; use Console.app with the device selected, or
   treat this as unavailable and rely on Notification Center.

## Identifiers used
- In-app toast: `SpendingBalanceReadyToast`.
- Received payment sheet: `ReceivedTransactionButton`.
