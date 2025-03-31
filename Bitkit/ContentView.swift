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
    @StateObject private var currency = CurrencyViewModel()
    @StateObject private var blocktank = BlocktankViewModel()
    @StateObject private var activity = ActivityListViewModel()
    @StateObject private var transfer = TransferViewModel()

    @State private var hideSplash = false
    @State private var removeSplash = false

    @State private var walletIsInitializing: Bool? = nil
    @State private var walletInitShouldFinish = false

    var body: some View {
        ZStack {
            if wallet.walletExists == true {
                // Mnemonic found in keychain
                if walletIsInitializing == true {
                    // New wallet is being created or restored
                    if case .errorStarting(let error) = wallet.nodeLifecycleState {
                        WalletInitResultView(result: .failed(error))
                    } else {
                        InitializingWalletView(shouldFinish: $walletInitShouldFinish) {
                            Logger.debug("Wallet finished initializing but node state is \(wallet.nodeLifecycleState)")

                            if wallet.nodeLifecycleState == .running {
                                walletIsInitializing = false
                            }
                        }
                    }
                } else if wallet.isRestoringWallet {
                    // Wallet exists and has been restored from backup. isRestoringWallet is to false inside below component
                    WalletInitResultView(result: .restored)
                } else {
                    HomeView()
                }
            } else if wallet.walletExists == false {
                NavigationView {
                    TermsView()
                        .navigationBarHidden(true)
                }
                .navigationViewStyle(.stack)
                .onAppear {
                    // Reset these values if the wallet is wiped
                    walletIsInitializing = nil
                    walletInitShouldFinish = false
                }
            }

            if !removeSplash {
                SplashView()
                    .opacity(hideSplash ? 0 : 1)
            }
        }
        .toastOverlay(toast: $app.currentToast, onDismiss: app.hideToast)
        .sheet(isPresented: $app.showNewTransaction) {
            NewTransactionSheet(details: $app.newTransaction)
        }
        .onChange(of: currency.hasStaleData) { _ in
            if currency.hasStaleData {
                app.toast(type: .error, title: "Rates currently unavailable", description: "An error has occurred. Please try again later.")
            }
        }
        .onChange(of: wallet.walletExists) { _ in
            Logger.info("Wallet exists state changed: \(wallet.walletExists?.description ?? "nil")")

            if wallet.walletExists != nil {
                withAnimation(.easeInOut(duration: 0.2).delay(0.2)) {
                    hideSplash = true
                }

                // Remove splash view after animation completes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    removeSplash = true
                }
            }

            guard wallet.walletExists == true else { return }

            wallet.addOnEvent(id: "toasts-and-sheets") { [weak app] lightningEvent in
                app?.handleLdkNodeEvent(lightningEvent)
            }

            wallet.addOnEvent(id: "activity-sync") { [weak activity] _ in
                Task {
                    // TODO: this might not be the best for performace to sync all payments on every event. Could switch to habdling the specific event.
                    try? await activity?.syncLdkNodePayments()
                }
            }

            Task {
                do {
                    try await wallet.start()
                    try await activity.syncLdkNodePayments()
                } catch {
                    Logger.error("Failed to start wallet")
                    Haptics.notify(.error)
                }

                // TODO: should be move to onboarding or when creating first invoice
                if UserDefaults.standard.string(forKey: "deviceToken") == nil {
                    StartupHandler.requestPushNotificationPermision { granted, error in
                        // If granted AppDelegate will receive the token and handle registration
                        if let error {
                            Logger.error(error, context: "Failed to request push notification permission")
                            app.toast(error)
                            return
                        }

                        if granted {
                            Logger.debug("Push notification permission granted, requesting device token")
                            Task {
                                do {
                                    // Sleep 1 second to ensure token is saved in AppDelegate
                                    try await Task.sleep(nanoseconds: 1_000_000_000)
                                    try await blocktank.registerDeviceForNotifications()
                                } catch {
                                    Logger.error(error, context: "Failed to register device for notifications, will retry on next app launch")
                                }
                            }
                        }
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
        .handleLightningStateOnScenePhaseChange()  // Will stop and start LDK-node in foreground app as needed
        .onChange(of: wallet.nodeLifecycleState) { state in
            if state == .initializing {
                walletIsInitializing = true
            } else if state == .running {
                walletInitShouldFinish = true
            } else if case .errorStarting = state {
                walletInitShouldFinish = true
            }
        }
        // Environment objects always at the end
        .environmentObject(app)
        .environmentObject(wallet)
        .environmentObject(currency)
        .environmentObject(blocktank)
        .environmentObject(activity)
        .environmentObject(transfer)
    }
}

#Preview {
    ContentView()
        .preferredColorScheme(.dark)
}
