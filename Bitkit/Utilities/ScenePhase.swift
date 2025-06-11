//
//  ScenePhase.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/15.
//

import SwiftUI
import UIKit

private struct HandleLightningStateOnScenePhaseChange: ViewModifier {
    @Environment(\.scenePhase) var scenePhase
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var blocktank: BlocktankViewModel

    let sleepTime: UInt64 = 500_000_000 // 0.5 seconds

    // Store the background task identifier
    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { newPhase in
                guard wallet.walletExists == true else {
                    return
                }

                Task { @MainActor in
                    Logger.debug("Scene phase changed: \(newPhase)")

                    if newPhase == .background {
                        do {
                            try await stopNodeIfNeeded()
                        } catch {
                            Logger.error(error, context: "Failed to stop LN")
                        }
                        return
                    }

                    if newPhase == .active {
                        // End background task if it's still active
                        if backgroundTaskID != .invalid {
                            UIApplication.shared.endBackgroundTask(backgroundTaskID)
                            backgroundTaskID = .invalid
                            Logger.debug("Ended background task on app becoming active")
                        }

                        if let transaction = NewTransactionSheetDetails.load() {
                            // Background extension received a transaction
                            NewTransactionSheetDetails.clear()
                            sheets.showSheet(.receivedTx, data: transaction)
                        }

                        do {
                            try await startNodeIfNeeded()
                        } catch {
                            Logger.error(error, context: "Failed to start LN")
                        }
                        Task {
                            await currency.refresh()
                        }

                        Task {
                            try? await blocktank.refreshOrders()
                        }
                    }
                }
            }
    }

    func stopNodeIfNeeded() async throws {
        if wallet.nodeLifecycleState == .stopped || wallet.nodeLifecycleState == .stopping {
            return
        }

        while wallet.nodeLifecycleState == .starting {
            Logger.debug("Waiting for LN to start first before stopping...")
            try await Task.sleep(nanoseconds: sleepTime)
        }

        guard scenePhase != .active else {
            Logger.debug("Scene phase is active, abandoning node stop...")
            return
        }

        guard wallet.nodeLifecycleState != .stopped && wallet.nodeLifecycleState != .stopping else {
            Logger.debug("LN is already stopped or stopping")
            return
        }

        // Begin a background task to request more execution time
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "StopLightningNode") {
            // This closure is called if the task expires
            Logger.debug("Background task for stopping Lightning node expired before completion")
            if self.backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
                self.backgroundTaskID = .invalid
            }
        }

        Logger.debug("Background task started with ID: \(backgroundTaskID.rawValue)")
        Logger.debug("App backgrounded Stopping node...")

        do {
            try await wallet.stopLightningNode()

            // End the background task if completed successfully
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
                Logger.debug("Background task ended after successful node stop")
            }

            //If we're stopped and we're not in the background, we need to start again
            if scenePhase == .active {
                try await startNodeIfNeeded()
            }
        } catch {
            // End the background task if there was an error
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
                Logger.debug("Background task ended after error stopping node")
            }
            throw error
        }
    }

    func startNodeIfNeeded() async throws {
        while wallet.nodeLifecycleState == .stopping {
            Logger.debug("Node is still stopping, waiting...")
            try await Task.sleep(nanoseconds: sleepTime)
        }

        guard wallet.nodeLifecycleState == .stopped else {
            Logger.debug("LN is already running or starting, abandoning restart...")
            return
        }

        guard scenePhase != .background else {
            Logger.debug("Scene phase is background, abandoning node restart...")
            return
        }

        Logger.debug("App active, starting LN service...")

        try await wallet.start()
    }
}

extension View {
    /// Stops and restarts lightning node when the app enters the background and foreground
    /// - Returns: View
    func handleLightningStateOnScenePhaseChange() -> some View {
        modifier(HandleLightningStateOnScenePhaseChange())
    }
}
