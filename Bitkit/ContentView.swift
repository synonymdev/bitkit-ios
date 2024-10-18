//
//  ContentView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/06/27.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var app = AppViewModel()
    @StateObject private var wallet = WalletViewModel()
    @StateObject private var blocktank = BlocktankViewModel()

    var body: some View {
        VStack {
            if wallet.walletExists == nil {
                ProgressView()
            } else if wallet.walletExists == true {
                HomeView()
            } else {
                WelcomeView()
            }
        }
        .toastOverlay(toast: $app.currentToast, onDismiss: app.hideToast)
        .sheet(isPresented: $app.showNewTransaction) {
            NewTransactionSheet(details: $app.newTransaction)
        }
        .onChange(of: wallet.walletExists) { _ in
            Logger.info("Wallet exists state changed: \(wallet.walletExists?.description ?? "nil")")
            if wallet.walletExists == true {
                Task {
                    do {
                        wallet.setOnEvent { lighntingEvent in
                            switch lighntingEvent {
                            case .paymentReceived(paymentId: _, paymentHash: _, amountMsat: let amountMsat):
                                app.showNewTransactionSheet(details: .init(type: .lightning, direction: .received, sats: amountMsat / 1000))
                            case .channelPending(channelId: _, userChannelId: _, formerTemporaryChannelId: _, counterpartyNodeId: _, fundingTxo: _):
                                app.toast(type: .success, title: "Channel pending", description: "Waiting for confirmation")
                            case .channelReady(channelId: let channelId, userChannelId: _, counterpartyNodeId: _):
                                // TODO: handle cjit as payment received
                                if let channel = LightningService.shared.channels?.first(where: { $0.channelId == channelId }) {
                                    app.toast(type: .success, title: "Channel opened", description: "Ready to send \(channel.outboundCapacityMsat / 1000) sats")
                                } else {
                                    app.toast(type: .error, title: "Channel opened", description: "Ready to send")
                                }
                            case .channelClosed(channelId: _, userChannelId: _, counterpartyNodeId: _, reason: _):
                                app.toast(type: .lightning, title: "Channel closed", description: "Balance moved from spending to savings")
                            case .paymentSuccessful(paymentId: _, paymentHash: _, feePaidMsat: let feePaidMsat):
                                app.showNewTransactionSheet(details: .init(type: .lightning, direction: .sent, sats: feePaidMsat ?? 0 / 1000))
                            case .paymentClaimable:
                                break
                            case .paymentFailed(paymentId: _, paymentHash: _, reason: let reason):
                                app.toast(type: .error, title: "Payment failed", description: reason.debugDescription)
                            }
                        }

                        try await wallet.start()
                    } catch {
                        Logger.error("Failed to start wallet")
                        Haptics.notify(.error)
                    }

                    // TODO: should be move to onboarding or when creating first invoice
                    if UserDefaults.standard.string(forKey: "deviceToken") == nil {
                        StartupHandler.requestPushNotificationPermision { _, error in
                            // If granted AppDelegate will receive the token and handle registration
                            if let error {
                                Logger.error(error, context: "Failed to request push notification permission")
                                app.toast(error)
                            }
                        }
                    } else {
                        Logger.debug("Device token already exists, assumed registered with Blocktank")
                    }
                }
            }
        }
        .task {
            do {
                try wallet.setWalletExistsState()
            } catch {
                app.toast(error)
            }
        }
        .handleLightningStateOnScenePhaseChange() // Will stop and start LN node as needed
        // Environment objects always at the end
        .environmentObject(app)
        .environmentObject(wallet)
        .environmentObject(blocktank)
    }
}

#Preview {
    ContentView()
}
