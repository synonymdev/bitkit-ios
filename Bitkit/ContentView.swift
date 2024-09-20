//
//  ContentView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/06/27.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var wallet = WalletViewModel()
    @StateObject private var blocktank = BlocktankViewModel()
    @StateObject private var toast = ToastViewModel()

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
        .toastOverlay(viewModel: toast)
        .onChange(of: wallet.walletExists) { _ in
            Logger.info("Wallet exists state changed: \(wallet.walletExists?.description ?? "nil")")
            if wallet.walletExists == true {
                Task {
                    try await wallet.startAll { lighntingEvent in
                        switch lighntingEvent {
                        case .paymentReceived(paymentId: _, paymentHash: _, amountMsat: let amountMsat):
                            toast.show(type: .success, title: "Received ⚡ \(amountMsat / 1000) sats", description: "Payment received")
                        case .channelPending(channelId: _, userChannelId: _, formerTemporaryChannelId: _, counterpartyNodeId: _, fundingTxo: _):
                            toast.show(type: .success, title: "Channel pending", description: "Waiting for confirmation")
                        case .channelReady(channelId: let channelId, userChannelId: _, counterpartyNodeId: _):
                            if let channel = LightningService.shared.channels?.first(where: { $0.channelId == channelId }) {
                                toast.show(type: .success, title: "Channel opened", description: "Ready to send \(channel.outboundCapacityMsat / 1000) sats")
                            } else {
                                toast.show(type: .error, title: "Channel opened", description: "Ready to send")
                            }
                        case .channelClosed(channelId: _, userChannelId: _, counterpartyNodeId: _, reason: _):
                            toast.show(type: .lightning, title: "Channel closed", description: "Balance moved from spending to savings")
                        case .paymentSuccessful:
                            break
                        case .paymentClaimable:
                            break
                        case .paymentFailed(paymentId: _, paymentHash: _, reason: _):
                            break
                        }
                    }

                    // TODO: should be move to onboarding or when creating first invoice
                    StartupHandler.requestPushNotificationPermision { _, error in
                        // If granted AppDelegate will receive the token and handle registration
                        if let error {
                            Logger.error(error, context: "Failed to request push notification permission")
                        }
                    }
                }
            }
        }
        .task {
            do {
                try wallet.setWalletExistsState()
            } catch {
                toast.show(error)
            }
        }
        .handleLightningStateOnScenePhaseChange() // Will stop and start LN node as needed
        // Environment objects always at the end
        .environmentObject(toast)
        .environmentObject(wallet)
        .environmentObject(blocktank)
    }
}

#Preview {
    ContentView()
}
