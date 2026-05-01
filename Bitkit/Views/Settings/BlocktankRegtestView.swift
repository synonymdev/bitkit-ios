import SwiftUI

struct BlocktankRegtestScreen: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var result: String = ""
    @State private var selectedMineBlockCount: Int = 1
    @State private var depositAmount: String = "100000"
    @State private var depositAddress: String = ""
    @State private var paymentInvoice: String = ""
    @State private var paymentAmount: String = ""
    @State private var forceCloseAfterSeconds: String = ""
    @State private var showingResult = false
    @State private var isDepositLoading = false
    @State private var isMiningLoading = false
    @State private var isPayInvoiceLoading = false
    @State private var isClosingChannelLoading = false

    private let mineBlockOptions = [1, 3, 20, 144]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: "Blocktank Regtest")
                .padding(.horizontal, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    depositSection
                    miningSection
                    lightningPaymentSection
                    channelCloseSection
                }
                .padding(.horizontal, 16)
                .bottomSafeAreaPadding()
            }
        }
        .navigationBarHidden(true)
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

    var depositSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader("Deposit")

            VStack(alignment: .leading, spacing: 8) {
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

                CustomButton(title: "Deposit", size: .small, isDisabled: depositAmount.isEmpty, isLoading: isDepositLoading) {
                    isDepositLoading = true
                    defer { isDepositLoading = false }
                    do {
                        Logger.debug("Initiating regtest deposit with amount: \(depositAmount)", context: "BlocktankRegtestScreen")
                        guard let amount = UInt64(depositAmount) else {
                            Logger.error("Invalid deposit amount: \(depositAmount)", context: "BlocktankRegtestScreen")
                            throw ValidationError("Invalid amount")
                        }

                        let newAddress = try await LightningService.shared.newAddress()
                        Logger.debug("Generated new address for deposit: \(newAddress)", context: "BlocktankRegtestScreen")

                        let txId = try await CoreService.shared.blocktank.regtestDepositFunds(
                            address: newAddress,
                            amountSat: amount
                        )
                        Logger.debug("Deposit successful with txId: \(txId)", context: "BlocktankRegtestScreen")
                        app.toast(type: .success, title: "Success", description: "Deposit successful. TxID: \(txId)")
                        depositAddress = newAddress
                        Task { try? await wallet.sync() }
                    } catch {
                        Logger.error("Regtest action failed: \(error.localizedDescription)", context: "BlocktankRegtestScreen")
                        app.toast(type: .error, title: "Regtest action failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    var miningSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader("Mining")

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(mineBlockOptions, id: \.self) { count in
                        Button {
                            selectedMineBlockCount = count
                        } label: {
                            BodyMSBText("\(count)", textColor: selectedMineBlockCount == count ? .white : .textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(selectedMineBlockCount == count ? Color.brandAccent : Color.white10)
                                .cornerRadius(8)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }

                CustomButton(title: "Mine Blocks", size: .small, isDisabled: selectedMineBlockCount == 0, isLoading: isMiningLoading) {
                    isMiningLoading = true
                    defer { isMiningLoading = false }
                    do {
                        let count = UInt32(selectedMineBlockCount)
                        Logger.debug("Starting regtest mining with block count: \(count)", context: "BlocktankRegtestScreen")
                        try await CoreService.shared.blocktank.regtestMineBlocks(count)
                        Logger.debug("Successfully mined \(count) blocks", context: "BlocktankRegtestScreen")
                        app.toast(type: .success, title: "Success", description: "Successfully mined \(count) blocks")
                        Task { try? await wallet.sync() }
                    } catch {
                        Logger.error("Regtest action failed: \(error.localizedDescription)", context: "BlocktankRegtestScreen")
                        app.toast(type: .error, title: "Regtest action failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    var lightningPaymentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader("Lightning Payment")

            VStack(alignment: .leading, spacing: 8) {
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

                CustomButton(title: "Pay Invoice", size: .small, isDisabled: paymentInvoice.isEmpty, isLoading: isPayInvoiceLoading) {
                    isPayInvoiceLoading = true
                    defer { isPayInvoiceLoading = false }
                    do {
                        Logger.debug(
                            "Initiating regtest payment with invoice: \(paymentInvoice), amount: \(paymentAmount)",
                            context: "BlocktankRegtestScreen"
                        )
                        let amount = paymentAmount.isEmpty ? nil : UInt64(paymentAmount) ?? 0
                        let paymentId = try await CoreService.shared.blocktank.regtestPayInvoice(paymentInvoice, amountSat: amount)
                        Logger.debug("Payment successful with ID: \(paymentId)", context: "BlocktankRegtestScreen")
                        app.toast(type: .success, title: "Success", description: "Payment successful. ID: \(paymentId)")
                    } catch {
                        Logger.error("Regtest action failed: \(error.localizedDescription)", context: "BlocktankRegtestScreen")
                        app.toast(type: .error, title: "Regtest action failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    var channelCloseSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader("Channel close from Blocktank side")

            VStack(alignment: .leading, spacing: 8) {
                TextField("Force close after (seconds)", text: $forceCloseAfterSeconds)
                    .keyboardType(.numberPad)

                if let channels = wallet.channels, !channels.isEmpty {
                    ForEach(channels, id: \.channelId) { channel in
                        VStack(alignment: .leading) {
                            CaptionMText(channel.channelId, textColor: .textSecondary)

                            HStack(spacing: 6) {
                                BodyMText("Ready:", textColor: .textPrimary)
                                Image(systemName: channel.isChannelReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: 17))
                                    .foregroundColor(channel.isChannelReady ? .greenAccent : .redAccent)
                            }
                            HStack(spacing: 6) {
                                BodyMText("Usable:", textColor: .textPrimary)
                                Image(systemName: channel.isUsable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: 17))
                                    .foregroundColor(channel.isUsable ? .greenAccent : .redAccent)
                            }

                            CustomButton(title: "Close This Channel", size: .small, isDisabled: false, isLoading: isClosingChannelLoading) {
                                isClosingChannelLoading = true
                                defer { isClosingChannelLoading = false }
                                do {
                                    Logger.debug("Closing channel: \(channel.channelId)", context: "BlocktankRegtestScreen")
                                    let closeAfter = forceCloseAfterSeconds.isEmpty ? nil : UInt64(forceCloseAfterSeconds)
                                    let closingTxId = try await CoreService.shared.blocktank.regtestRemoteCloseChannel(
                                        channel: channel,
                                        forceCloseAfterSeconds: closeAfter
                                    )
                                    Logger.debug("Channel closed successfully with txId: \(closingTxId)", context: "BlocktankRegtestScreen")
                                    app.toast(type: .success, title: "Success", description: "Channel closed. Closing TxID: \(closingTxId)")
                                } catch {
                                    Logger.error("Regtest action failed: \(error.localizedDescription)", context: "BlocktankRegtestScreen")
                                    app.toast(type: .error, title: "Regtest action failed: \(error.localizedDescription)")
                                }
                            }
                            .padding(.top, 8)
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    BodyMText("No channels available")
                        .padding(.vertical, 8)
                }
            }
        }
    }
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
