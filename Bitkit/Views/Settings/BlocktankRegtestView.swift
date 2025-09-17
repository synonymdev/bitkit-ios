import SwiftUI

struct RegtestButton: View {
    let title: String
    let action: () async throws -> Void

    @EnvironmentObject var app: AppViewModel
    @State private var isLoading = false

    var body: some View {
        Button(isLoading ? "Loading..." : title) {
            isLoading = true
            Task {
                do {
                    try await action()
                } catch {
                    Logger.error("Regtest action failed: \(error.localizedDescription)", context: "BlocktankRegtestView")
                    app.toast(type: .error, title: "Regtest action failed: \(error.localizedDescription)")
                }
                isLoading = false
            }
        }
        .disabled(isLoading)
        .opacity(isLoading ? 0.5 : 1)
    }
}

struct BlocktankRegtestView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @State private var result: String = ""
    @State private var mineBlockCount: String = "1"
    @State private var depositAmount: String = "100000"
    @State private var depositAddress: String = ""
    @State private var paymentInvoice: String = ""
    @State private var paymentAmount: String = ""
    @State private var forceCloseAfterSeconds: String = ""
    @State private var showingResult = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: "Blocktank Regtest")
                .padding(.horizontal, 16)

            List {
                serverInfoSection
                depositSection
                miningSection
                lightningPaymentSection
                channelCloseSection
            }
        }
        .navigationBarHidden(true)
        .bottomSafeAreaPadding()
        .onAppear {
            // Generate a fresh address when the view appears
            Task {
                do {
                    let newAddress = try await LightningService.shared.newAddress()
                    depositAddress = newAddress
                } catch {
                    // Fallback to wallet's current address if generation fails
                    depositAddress = wallet.onchainAddress
                }
            }
        }
    }

    var serverInfoSection: some View {
        Section {
            Text(Env.blocktankBaseUrl)
        } footer: {
            Text("These actions are executed on the staging Blocktank server node.")
        }
    }

    var depositSection: some View {
        Section {
            HStack {
                TextField("Address", text: $depositAddress)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Button {
                    if let string = UIPasteboard.general.string {
                        depositAddress = string
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }

                Button {
                    Task {
                        do {
                            let newAddress = try await LightningService.shared.newAddress()
                            depositAddress = newAddress
                        } catch {
                            app.toast(type: .error, title: "Failed to generate address", description: error.localizedDescription)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }

            TextField("Amount (sats)", text: $depositAmount)
                .keyboardType(.numberPad)

            RegtestButton(title: "Make Deposit") {
                Logger.debug("Initiating regtest deposit with amount: \(depositAmount)", context: "BlocktankRegtestView")
                guard let amount = UInt64(depositAmount) else {
                    Logger.error("Invalid deposit amount: \(depositAmount)", context: "BlocktankRegtestView")
                    throw ValidationError("Invalid amount")
                }

                // Generate a new address for each deposit
                let newAddress = try await LightningService.shared.newAddress()
                Logger.debug("Generated new address for deposit: \(newAddress)", context: "BlocktankRegtestView")

                let txId = try await CoreService.shared.blocktank.regtestDepositFunds(
                    address: newAddress,
                    amountSat: amount
                )
                Logger.debug("Deposit successful with txId: \(txId)", context: "BlocktankRegtestView")
                app.toast(type: .success, title: "Success", description: "Deposit successful. TxID: \(txId)")

                // Update the displayed address to the new one
                depositAddress = newAddress

                // Sync wallet after deposit without waiting
                Task {
                    try? await wallet.sync()
                }
            }
            .disabled(depositAmount.isEmpty)
            .tint(.orange)
        } header: {
            Text("Deposit")
        }
    }

    var miningSection: some View {
        Section {
            HStack {
                TextField("Block count", text: $mineBlockCount)
                    .keyboardType(.numberPad)

                RegtestButton(title: "Mine Blocks") {
                    Logger.debug("Starting regtest mining with block count: \(mineBlockCount)", context: "BlocktankRegtestView")
                    guard let count = UInt32(mineBlockCount) else {
                        Logger.error("Invalid block count: \(mineBlockCount)", context: "BlocktankRegtestView")
                        throw ValidationError("Invalid block count")
                    }
                    try await CoreService.shared.blocktank.regtestMineBlocks(count)
                    Logger.debug("Successfully mined \(count) blocks", context: "BlocktankRegtestView")
                    app.toast(type: .success, title: "Success", description: "Successfully mined \(count) blocks")

                    // Sync wallet after mining blocks without waiting
                    Task {
                        try? await wallet.sync()
                    }
                }
                .tint(.orange)
            }
        } header: {
            Text("Mining")
        }
    }

    var lightningPaymentSection: some View {
        Section {
            HStack {
                TextField("Invoice", text: $paymentInvoice)

                Button {
                    if let string = UIPasteboard.general.string {
                        paymentInvoice = string
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
            }

            TextField("Amount (optional, sats)", text: $paymentAmount)
                .keyboardType(.numberPad)

            RegtestButton(title: "Pay Invoice") {
                Logger.debug("Initiating regtest payment with invoice: \(paymentInvoice), amount: \(paymentAmount)", context: "BlocktankRegtestView")
                let amount = paymentAmount.isEmpty ? nil : UInt64(paymentAmount) ?? 0
                let paymentId = try await CoreService.shared.blocktank.regtestPayInvoice(paymentInvoice, amountSat: amount)
                Logger.debug("Payment successful with ID: \(paymentId)", context: "BlocktankRegtestView")
                app.toast(type: .success, title: "Success", description: "Payment successful. ID: \(paymentId)")
            }
            .disabled(paymentInvoice.isEmpty)
            .tint(.orange)
        } header: {
            Text("Lightning Payment")
        }
    }

    var channelCloseSection: some View {
        Section {
            TextField("Force close after (seconds)", text: $forceCloseAfterSeconds)
                .keyboardType(.numberPad)

            if let channels = wallet.channels, !channels.isEmpty {
                ForEach(channels, id: \.channelId) { channel in
                    VStack(alignment: .leading) {
                        Text(channel.channelId)
                            .font(.caption)

                        Text("Ready: \(channel.isChannelReady ? "✅" : "❌")")
                        Text("Usable: \(channel.isUsable ? "✅" : "❌")")

                        RegtestButton(title: "Close This Channel") {
                            Logger.debug("Closing channel: \(channel.channelId)", context: "BlocktankRegtestView")

                            let closeAfter = forceCloseAfterSeconds.isEmpty ? nil : UInt64(forceCloseAfterSeconds)

                            let closingTxId = try await CoreService.shared.blocktank.regtestRemoteCloseChannel(
                                channel: channel,
                                forceCloseAfterSeconds: closeAfter
                            )

                            Logger.debug("Channel closed successfully with txId: \(closingTxId)", context: "BlocktankRegtestView")
                            app.toast(type: .success, title: "Success", description: "Channel closed. Closing TxID: \(closingTxId)")
                        }
                        .tint(.red)
                        .padding(.top, 8)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Text("No channels available")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }
        } header: {
            Text("Channel close from Blocktank side")
        }
    }
}

#Preview {
    NavigationStack {
        BlocktankRegtestView()
            .environmentObject(AppViewModel())
            .environmentObject(WalletViewModel())
    }
    .preferredColorScheme(.dark)
}

private struct ValidationError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
