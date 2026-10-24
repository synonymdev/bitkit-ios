# Channel-ready notification journeys

One journey remains: `non-cjit-channel-no-payment-notification.xml`. Opening a regular (non-CJIT)
Lightning channel must not be reported as a received payment, whether it is an "Incoming Payment"
notification or a stack of duplicates. When the app is in the foreground the only feedback is the
in-app "Spending balance ready" toast.

The folder keeps its name so the file path stays stable for the Android twin.

## Retired journeys

`cjit-background-notification.xml` and `cjit-push-single-notification.xml` were retired because
Blocktank channel purchases, CJIT included, were removed (synonymdev/bitkit-ios#1097). They paid a
CJIT order through the LSP and asserted a single Blocktank-pushed notification with the app
backgrounded and killed. Nothing in the app creates a CJIT order now, so there is no way to drive the
push.

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
- **Android issue #2 (double notification)** ported as "exactly one notification" in the retired CJIT
  journeys. iOS has no foreground service and no `WakeNodeWorker`; the Notification Service Extension
  is the only poster, so a duplicate would have to come from a duplicate push.
- **Android issue #3 (channel open reported as a payment) ports directly** and is the journey that
  remains. A manual channel is not a Blocktank order, so no `orderPaymentConfirmed` push arrives and
  no Bitkit notification is expected; none may read "Incoming Payment".

## Preconditions
- **A physical device, not the simulator.** The journey reads Notification Center to prove no
  payment notification was posted, which needs an app registered for real APNs pushes. Nothing runs this suite automatically, and that is not a gap to
  fill here — `ai-device-tests.yml` runs `TrezorBridgeDashboardUITests` on a simulator and is not a
  journey runner. Run these by hand against an attached device. `test-push-server/` can drive a hand-built push at a known device token when you need to exercise
  the extension without the LSP.
- Onboarded regtest wallet connected to the LSP, with notifications authorized and
  "Get paid when Bitkit is closed" enabled in Settings → Notifications.
- A positive on-chain balance and no Lightning channel yet. This build has no Transfer To Spending,
  so the journey opens a manual channel to the LSP node: Settings › Advanced › Lightning Connections ›
  add connection › Manual Setup. See [Getting a Lightning channel](../README.md#getting-a-lightning-channel).

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
