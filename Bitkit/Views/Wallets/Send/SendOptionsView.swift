//
//  SendOptionsView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import SwiftUI

struct SendOptionsView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var wallet: WalletViewModel

    var body: some View {
        NavigationView {
            sendOptionsContent
        }
    }

    var sendOptionsContent: some View {
        VStack {
            Text("Send Bitcoin")
                .font(.title)
                .padding()

            Spacer()

            List {
                Section("To") {
                    HStack {
                        Button("Paste Invoice") {
                            handlePaste()
                        }
                    }

                    HStack {
                        NavigationLink(destination: SendEnterManuallyView()) {
                            Text("Enter Manually")
                        }
                    }

                    HStack {
                        NavigationLink(destination: ScannerView()) {
                            Text("Scan QR Code")
                        }
                    }
                }
            }
        }
        .onAppear {
            wallet.syncState()
        }
        .background(
            NavigationLink(
                destination: SendAmountView(),
                isActive: $app.showSendAmountView
            ) { EmptyView() }
        )
        .background(
            NavigationLink(
                destination: SendConfirmationView(),
                isActive: $app.showSendConfirmationView
            ) { EmptyView() }
        )
    }

    func handlePaste() {
        guard let uri = UIPasteboard.general.string else {
            Logger.error("No data in clipboard")
            app.toast(type: .warning, title: "No data in clipboard", description: "")
            return
        }

        Haptics.play(.pastedFromClipboard)

        Task { @MainActor in
            do {
                try await app.handleScannedData(uri)
            } catch {
                Logger.error(error, context: "Failed to read data from clipboard")
                app.toast(error)
            }
        }
    }
}

#Preview {
    SendOptionsView()
        .environmentObject(AppViewModel())
        .environmentObject(WalletViewModel())
}
