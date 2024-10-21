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
            VStack {
                Text("Send Bitcoin")
                    .font(.title)
                    .padding()

                Spacer()

                List {
                    Section("To") {
                        HStack {
                            Button("Contact") {
                                app.toast(type: .warning, title: "Coming soon", description: "This feature is not available yet")
                            }
                        }

                        HStack {
                            Button("Paste Invoice") {
                                guard let uri = UIPasteboard.general.string else {
                                    Logger.error("No data in clipboard")
                                    return
                                }

                                do {
                                    let data = try ScannedData(uri)
                                    Logger.debug("Pasted data: \(data)")
                                    app.scannedData = data

                                    Haptics.play(.pastedFromClipboard)

                                    // TODO: nav to next view instead
                                    if let option = data.options.first {
                                        switch option {
                                        case .onchain(let address, let amount, let label, let message):
                                            app.toast(type: .success, title: "Onchain", description: "Onchain")
                                        case .bolt11(let invoice):
                                            Task {
                                                do {
                                                    try await wallet.send(bolt11: invoice)
                                                } catch {
                                                    app.toast(error)
                                                }
                                            }
                                        }
                                    }
                                } catch {
                                    Logger.error(error, context: "Failed to read data from clipboard")
                                    app.toast(error)
                                }
                            }
                        }

                        HStack {
                            NavigationLink(destination: SendEnterManually()) {
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
        }
        .onAppear {
            wallet.syncState()
        }
    }
}

#Preview {
    SendOptionsView()
        .environmentObject(AppViewModel())
        .environmentObject(WalletViewModel())
}
