//
//  ScenePhase.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/15.
//

import SwiftUI

private struct HandleLightningStateOnScenePhaseChange: ViewModifier {
    @Environment(\.scenePhase) var scenePhase
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var blocktank: BlocktankViewModel

    let sleepTime: UInt64 = 500_000_000  // 0.5 seconds

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
                        if let transaction = NewTransactionSheetDetails.load() {
                            // Background extension received a transaction
                            NewTransactionSheetDetails.clear()
                            app.showNewTransactionSheet(details: transaction)
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

        Logger.debug("App backgrounded Stopping node...")

        try await wallet.stopLightningNode()

        //If we're stopped and we're not in the background, we need to start again
        if scenePhase == .active {
            try await startNodeIfNeeded()
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
