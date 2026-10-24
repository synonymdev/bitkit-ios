# Notification-permission journeys

This suite is retired. Every journey in it reached the background-setup toggle through a Blocktank
channel purchase, and those were removed in synonymdev/bitkit-ios#1097:

- `receive-cjit-confirm-notification-toggle.xml` and `toggle-off-and-system-settings-route.xml` used the
  Receive → CJIT confirm screen (`ReceiveCjitConfirm`), reached through "Receive Lightning funds".
- `receive-cjit-liquidity-notification-toggle.xml` used the Receive → CJIT liquidity screen
  (`ReceiveCjitLiquidity`).
- `transfer-spending-confirm-notification-toggle.xml` used the Transfer → Spending confirm screen
  (`SpendingConfirmNotificationSwitch`), reached through "Transfer To Spending".

No button in the UI navigates to those screens any more, so the toggle's permission behaviour (the
one-shot `UNUserNotificationCenter.requestAuthorization` alert on toggling on; toggling off only
unregisters push) is no longer reachable on a device through these routes. Settings › Notifications,
with its "Customize in iOS Bitkit Settings" button (id `NotificationsOpenSystemSettings`), is a
separate entry point that no journey covers yet.

The reset for a fresh authorization state, should a journey for another entry point be written:
`xcrun simctl uninstall <device> to.bitkit`, then `xcodebuildmcp simulator build-and-run` and
re-onboard the wallet.
