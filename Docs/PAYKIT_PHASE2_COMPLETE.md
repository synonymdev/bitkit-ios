# Paykit Integration - Phase 2 Completed

## Overview

Phase 2 of the Paykit integration has been completed. This phase added support for Paykit-specific push notifications to both iOS and Android platforms.

## Changes Made

### iOS Changes

#### 1. BlocktankNotificationType.swift
Added four new Paykit notification types:
- `paykitPaymentRequest` - For incoming payment requests requiring processing
- `paykitSubscriptionDue` - For subscription payments that are due
- `paykitAutoPayExecuted` - For completed auto-pay executions
- `paykitSubscriptionFailed` - For failed subscription payments

Updated the `feature` property to properly route Paykit notifications with "paykit." prefix instead of "blocktank."

#### 2. NotificationService.swift
Added `handlePaykitNotification()` method that:
- Processes incoming Paykit payment requests and prepares notification display
- Handles subscription due notifications
- Shows confirmation for auto-pay executions with amount
- Displays subscription failure notifications with reason

The method is called after the LDK node has successfully started, ensuring Paykit can process requests when the wallet is ready.

### Android Changes

#### 1. BlocktankNotificationType.kt
Added the same four Paykit notification types:
- `paykitPaymentRequest`
- `paykitSubscriptionDue`
- `paykitAutoPayExecuted`
- `paykitSubscriptionFailed`

Updated the `toString()` method to route Paykit notifications properly.

#### 2. WakeNodeWorker.kt
Added `handlePaykitNotification()` method with similar functionality to iOS:
- Processes payment requests and prepares notification
- Handles subscription payment notifications
- Shows auto-pay execution confirmations
- Displays subscription failure details

Added imports for the new notification types.

#### 3. strings.xml
Added new string resources for Paykit notifications:
- `notification_autopay_executed_title`
- `notification_payment_request_body`
- `notification_payment_request_title`
- `notification_sent`
- `notification_subscription_due_body`
- `notification_subscription_due_title`
- `notification_subscription_failed_title`

All strings added in alphabetical order per project conventions.

## Testing

### Android
- Compilation successful: `./gradlew compileDevDebugKotlin` passed
- No linter errors detected

### iOS
- No linter errors detected
- SwiftFormat validation passed
- Full simulator build blocked by missing `PaykitMobile.xcframework` simulator binaries (unrelated to notification changes)

## Architecture Notes

The notification handling follows the existing pattern:
1. Notifications arrive encrypted via Firebase (Android) or APNs (iOS)
2. The notification service extension/worker decrypts the payload
3. The LDK node is started if not already running
4. Paykit-specific notifications are routed to the new handler methods
5. Notifications are displayed to the user with appropriate content

## Next Steps

To fully utilize these notification types:
1. Backend must send notifications with the appropriate type field
2. Paykit services must be integrated to actually process payment requests
3. Subscription monitoring must be implemented to trigger due/failed notifications
4. Auto-pay execution must trigger notification sending

## Dependencies

This phase depends on:
- Phase 0: Workspace setup (✅ completed)
- Phase 1: Paykit initialization on node lifecycle (✅ completed)

This phase enables:
- Phase 3+: Full Paykit feature implementation with async waking support

