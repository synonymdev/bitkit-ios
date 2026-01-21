import SwiftUI
import UIKit
import UserNotifications

private struct HandleLightningStateOnScenePhaseChange: ViewModifier {
    @Environment(\.scenePhase) var scenePhase
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var blocktank: BlocktankViewModel

    // Store the background task identifier
    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    // Track if we need to start node after it finishes stopping
    @State private var pendingStartAfterStop = false
    // Delay before stopping node (don't stop for quick background trips)
    @State private var stopNodeWorkItem: DispatchWorkItem?

    // Only stop node if app has been in background for this long
    private let backgroundStopDelay: TimeInterval = 90.0

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { newPhase in
                guard wallet.walletExists == true else {
                    return
                }

                Logger.debug("Scene phase changed: \(newPhase)")

                if newPhase == .background {
                    app.resetAppStatusInit()
                    pendingStartAfterStop = false
                    scheduleNodeStop()
                    return
                }

                if newPhase == .active {
                    // Cancel any pending node stop
                    cancelScheduledNodeStop()

                    // End background task if it's still active
                    if backgroundTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(backgroundTaskID)
                        backgroundTaskID = .invalid
                        Logger.debug("Ended background task on app becoming active")
                    }

                    // Check for background-received transaction
                    if let transaction = ReceivedTxSheetDetails.load() {
                        ReceivedTxSheetDetails.clear()
                        sheets.showSheet(.receivedTx, data: transaction)
                    }

                    // Remove delivered notifications
                    Task {
                        await clearDeliveredNotifications()
                    }

                    startNodeIfNeeded()

                    Task {
                        await currency.refresh()
                    }

                    Task {
                        try? await blocktank.refreshOrders()
                    }
                }
            }
            .onChange(of: wallet.nodeLifecycleState) { newState in
                // Handle pending start after node finishes stopping
                if newState == .stopped && pendingStartAfterStop && scenePhase == .active {
                    pendingStartAfterStop = false
                    startNodeIfNeeded()
                }
            }
    }

    /// Schedule node stop after a delay - allows quick background trips without restart
    func scheduleNodeStop() {
        // Cancel any existing scheduled stop
        stopNodeWorkItem?.cancel()

        let workItem = DispatchWorkItem { [self] in
            stopNodeIfNeeded()
        }
        stopNodeWorkItem = workItem

        Logger.debug("Scheduling node stop in \(backgroundStopDelay)s...")
        DispatchQueue.main.asyncAfter(deadline: .now() + backgroundStopDelay, execute: workItem)
    }

    /// Cancel scheduled node stop (called when returning to foreground quickly)
    func cancelScheduledNodeStop() {
        if let workItem = stopNodeWorkItem, !workItem.isCancelled {
            workItem.cancel()
            Logger.debug("Cancelled scheduled node stop - quick return to foreground")
        }
        stopNodeWorkItem = nil
    }

    func stopNodeIfNeeded() {
        // Already stopped or stopping
        if wallet.nodeLifecycleState == .stopped || wallet.nodeLifecycleState == .stopping {
            return
        }

        if wallet.nodeLifecycleState == .starting {
            Logger.debug("Node is starting, can't stop yet")
            return
        }

        guard scenePhase != .active else {
            Logger.debug("Scene phase is active, abandoning node stop...")
            return
        }

        guard wallet.nodeLifecycleState == .running else {
            Logger.debug("LN is not in a stoppable state: \(wallet.nodeLifecycleState)")
            return
        }

        // Begin a background task to request more execution time
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "StopLightningNode") {
            // This closure is called if the task expires
            Logger.debug("Background task for stopping Lightning node expired before completion")
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }

        Logger.debug("Background task started with ID: \(backgroundTaskID.rawValue)")
        Logger.debug("App backgrounded, stopping node...")

        Task {
            do {
                try await wallet.stopLightningNode()

                await MainActor.run {
                    // End the background task if completed successfully
                    if backgroundTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(backgroundTaskID)
                        backgroundTaskID = .invalid
                        Logger.debug("Background task ended after successful node stop")
                    }

                    // If we're stopped and we're not in the background, we need to start again
                    if scenePhase == .active {
                        startNodeIfNeeded()
                    }
                }
            } catch {
                Logger.error(error, context: "Failed to stop LN")
                await MainActor.run {
                    // End the background task if there was an error
                    if backgroundTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(backgroundTaskID)
                        backgroundTaskID = .invalid
                        Logger.debug("Background task ended after error stopping node")
                    }
                }
            }
        }
    }

    func startNodeIfNeeded() {
        // If node is stopping, mark that we want to start after it stops
        if wallet.nodeLifecycleState == .stopping {
            Logger.debug("Node is stopping, will start after it finishes")
            pendingStartAfterStop = true
            return
        }

        // Already running or starting
        guard wallet.nodeLifecycleState == .stopped else {
            Logger.debug("LN is already running or starting, abandoning restart...")
            return
        }

        guard scenePhase != .background else {
            Logger.debug("Scene phase is background, abandoning node restart...")
            return
        }

        Logger.debug("App active, starting LN service...")

        Task {
            do {
                try await wallet.start()
            } catch {
                Logger.error(error, context: "Failed to start LN")
            }
        }
    }

    /// Removes all delivered notifications from Notification Center
    /// The app will handle processing any relevant notifications when it opens
    func clearDeliveredNotifications() async {
        let center = UNUserNotificationCenter.current()
        let deliveredNotifications = await center.deliveredNotifications()

        guard !deliveredNotifications.isEmpty else { return }

        let identifiers = deliveredNotifications.map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        Logger.debug("Removed \(identifiers.count) notification(s) from Notification Center")
    }
}

extension View {
    /// Stops and restarts lightning node when the app enters the background and foreground
    /// - Returns: View
    func handleLightningStateOnScenePhaseChange() -> some View {
        modifier(HandleLightningStateOnScenePhaseChange())
    }
}
