# Notification-permission journeys

Verify that the "Enable background setup" toggle — shown on the Receive → CJIT confirm screen, the
Receive → CJIT liquidity screen and the Transfer → Spending confirm screen — drives the iOS
notification authorization prompt, and that the app's own notification settings own the route into
the system Settings app.

## iOS vs Android

Android requests `POST_NOTIFICATIONS` at the toggle and, once granted, re-tapping the toggle deep
links into system settings. iOS differs in two ways that these journeys are written around:

- **The prompt is one-shot and system-owned.** `PushNotificationManager.requestPermission()` calls
  `UNUserNotificationCenter.requestAuthorization`, which only shows the alert while the status is
  `notDetermined`. Once the user has answered once, toggling on is silent.
- **Toggling off does not open system settings.** `MainNavView`'s `onChange(of:)` simply calls
  `notificationManager.unregister()`. The route into the iOS Settings app is a dedicated button on
  Settings → Notifications (id `NotificationsOpenSystemSettings`), which is what
  `toggle-off-and-system-settings-route.xml` covers instead of Android's
  `toggle-off-opens-system-settings.xml`.

## Preconditions
- Onboarded dev wallet with the node connected to the LSP so a CJIT order can be quoted, and (for
  the transfer journey) a positive on-chain Savings balance.
- **Notification authorization must be `notDetermined`** for the three "requests permission"
  journeys. The alert is one-shot per install, so reset it by reinstalling the app:
  `xcrun simctl uninstall <device> to.bitkit` then `xcodebuildmcp simulator build-and-run`.
  Re-onboarding the wallet is part of that reset.
- `settings.enableNotifications` must start **off** so the toggles read unchecked.

## Gotcha: one setting, three toggles

All three switches bind to the same `settings.enableNotifications`. Flipping one flips the other two,
so run these journeys one per app state — do not chain them expecting an unchecked toggle on the
second screen.

## Identifiers used
- Receive CJIT: amount screen `ReceiveCjitAmount`, field `ReceiveCjitAmountNumberField`,
  continue `ReceiveCjitAmountContinue`; confirm screen `ReceiveCjitConfirm` with switch
  `ReceiveConfirmNotificationSwitch`; liquidity screen `ReceiveCjitLiquidity` with switch
  `ReceiveLiquidityNotificationSwitch`.
- Transfer: `SpendingAmount`, `SpendingAmountAvailable`, `SpendingAmountContinue`, and the confirm
  screen switch `SpendingConfirmNotificationSwitch`.
- Settings → Notifications: `NotificationsOpenSystemSettings`.
