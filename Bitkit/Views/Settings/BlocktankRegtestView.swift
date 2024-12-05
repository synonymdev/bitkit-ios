import SwiftUI

struct BlocktankRegtestView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @State private var result: String = ""
    @State private var mineBlockCount: String = "1"
    @State private var depositAmount: String = "12300"
    @State private var depositAddress: String = ""
    @State private var paymentInvoice: String = ""
    @State private var paymentAmount: String = ""
    @State private var fundingTxId: String = ""
    @State private var vout: String = "0"
    @State private var forceCloseAfter: String = "86400"
    @State private var showingResult = false
    @State private var isMining = false
    @State private var isDepositing = false
    
    var body: some View {
        List {
            Section {
                Text(Env.blocktankBaseUrl)
            } footer: {
                Text("These actions are executed on the staging Blocktank server node.")
            }
            
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
                }
                    
                TextField("Amount (sats)", text: $depositAmount)
                    .keyboardType(.numberPad)
                
                Button(isDepositing ? "Depositing..." : "Make Deposit") {
                    Task {
                        Logger.debug("Initiating regtest deposit with address: \(depositAddress), amount: \(depositAmount)", context: "BlocktankRegtestView")
                        isDepositing = true
                        do {
                            guard let amount = Int(depositAmount) else {
                                Logger.error("Invalid deposit amount: \(depositAmount)", context: "BlocktankRegtestView")
                                throw ValidationError("Invalid amount")
                            }
                            let txId = try await BlocktankService.shared.regtestDeposit(
                                address: depositAddress,
                                amountSat: amount
                            )
                            Logger.debug("Deposit successful with txId: \(txId)", context: "BlocktankRegtestView")
                            app.toast(type: .success, title: "Success", description: "Deposit successful. TxID: \(txId)")
                        } catch {
                            Logger.error("Deposit failed: \(error.localizedDescription)", context: "BlocktankRegtestView")
                            app.toast(type: .error, title: "Failed to deposit", description: error.localizedDescription)
                        }
                        isDepositing = false
                    }
                }
                .disabled((depositAddress.isEmpty && wallet.onchainAddress.isEmpty) || isDepositing)
                .tint(.orange)
            } header: {
                Text("Deposit")
            }
            
            Section {
                HStack {
                    TextField("Block count", text: $mineBlockCount)
                        .keyboardType(.numberPad)
                    
                    Button(isMining ? "Mining..." : "Mine Blocks") {
                        Task {
                            Logger.debug("Starting regtest mining with block count: \(mineBlockCount)", context: "BlocktankRegtestView")
                            isMining = true
                            do {
                                guard let count = Int(mineBlockCount) else {
                                    Logger.error("Invalid block count: \(mineBlockCount)", context: "BlocktankRegtestView")
                                    throw ValidationError("Invalid block count")
                                }
                                try await BlocktankService.shared.regtestMine(count: count)
                                Logger.debug("Successfully mined \(count) blocks", context: "BlocktankRegtestView")
                                app.toast(type: .success, title: "Success", description: "Successfully mined \(count) blocks")
                            } catch {
                                Logger.error("Mining failed: \(error.localizedDescription)", context: "BlocktankRegtestView")
                                app.toast(type: .error, title: "Failed to mine", description: error.localizedDescription)
                            }
                            isMining = false
                        }
                    }
                    .disabled(isMining)
                    .tint(.orange)
                }
            } header: {
                Text("Mining")
            }
            
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
                
                Button("Pay Invoice") {
                    Task {
                        Logger.debug("Initiating regtest payment with invoice: \(paymentInvoice), amount: \(paymentAmount)", context: "BlocktankRegtestView")
                        do {
                            let amount = paymentAmount.isEmpty ? nil : Int(paymentAmount)
                            let paymentId = try await BlocktankService.shared.regtestPay(
                                invoice: paymentInvoice,
                                amountSat: amount
                            )
                            Logger.debug("Payment successful with ID: \(paymentId)", context: "BlocktankRegtestView")
                            app.toast(type: .success, title: "Success", description: "Payment successful. ID: \(paymentId)")
                        } catch {
                            Logger.error("Payment failed: \(error.localizedDescription)", context: "BlocktankRegtestView")
                            app.toast(type: .error, title: "Failed to pay invoice from LND", description: error.localizedDescription)
                        }
                    }
                }
                .disabled(paymentInvoice.isEmpty)
                .tint(.orange)
            } header: {
                Text("Lightning Payment")
            }
            
            Section {
                TextField("Funding TxID", text: $fundingTxId)
                TextField("Vout", text: $vout)
                    .keyboardType(.numberPad)
                TextField("Force close after (seconds)", text: $forceCloseAfter)
                    .keyboardType(.numberPad)
                
                Button("Close Channel") {
                    Task {
                        Logger.debug("Initiating channel close with fundingTxId: \(fundingTxId), vout: \(vout), forceCloseAfter: \(forceCloseAfter)", context: "BlocktankRegtestView")
                        do {
                            guard let voutNum = Int(vout),
                                  let closeAfter = Int(forceCloseAfter)
                            else {
                                Logger.error("Invalid channel close parameters - vout: \(vout), forceCloseAfter: \(forceCloseAfter)", context: "BlocktankRegtestView")
                                throw ValidationError("Invalid input values")
                            }
                            let closingTxId = try await BlocktankService.shared.regtestCloseChannel(
                                fundingTxId: fundingTxId,
                                vout: voutNum,
                                forceCloseAfterS: closeAfter
                            )
                            Logger.debug("Channel closed successfully with txId: \(closingTxId)", context: "BlocktankRegtestView")
                            app.toast(type: .success, title: "Success", description: "Channel closed. Closing TxID: \(closingTxId)")
                        } catch {
                            Logger.error("Channel close failed: \(error.localizedDescription)", context: "BlocktankRegtestView")
                            app.toast(error)
                        }
                    }
                }
                .disabled(fundingTxId.isEmpty)
                .tint(.orange)
            } header: {
                Text("Channel Close")
            }
        }
        .navigationTitle("Blocktank Regtest")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            depositAddress = wallet.onchainAddress
        }
    }
}

#Preview {
    NavigationView {
        BlocktankRegtestView()
            .environmentObject(AppViewModel())
            .environmentObject(WalletViewModel())
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
