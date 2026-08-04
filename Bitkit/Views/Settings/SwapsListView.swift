import BitkitCore
import SwiftUI

struct SwapsListView: View {
    @State private var swaps: [BoltzSwap] = []
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        List {
            if let errorMessage {
                Text("Error: \(errorMessage)")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if swaps.isEmpty, !isLoading, errorMessage == nil {
                Text("No swaps found")
                    .font(.caption)
                    .foregroundColor(.gray)
            } else {
                ForEach(swaps, id: \.id) { swap in
                    NavigationLink(value: Route.swapDetail(id: swap.id)) {
                        SwapRow(swap: swap)
                    }
                }
            }
        }
        .navigationTitle("Swaps")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await refresh()
        }
        .task {
            await refresh()
        }
    }

    private func refresh() async {
        do {
            let list = try await BoltzService.shared.listSwaps()
            swaps = list.sorted { $0.createdAt > $1.createdAt }
            errorMessage = nil
        } catch {
            Logger.error("Failed to list swaps", context: error.localizedDescription)
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct SwapRow: View {
    let swap: BoltzSwap

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(swap.id)
                    .font(.system(size: swap.id.count > 20 ? 10 : 12, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Text(String(describing: swap.status))
                    .font(.caption)
                    .padding(4)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(4)
            }

            HStack {
                VStack(alignment: .leading) {
                    Text("Type")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text(String(describing: swap.swapType))
                        .font(.subheadline)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Amount")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text("\(swap.amountSat) sats")
                        .font(.subheadline)
                }
            }

            HStack {
                VStack(alignment: .leading) {
                    Text("Receives")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text(swap.onchainAmountSat.map { "\($0) sats" } ?? "-")
                        .font(.subheadline)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Created")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text(formatEpochSeconds(swap.createdAt))
                        .font(.subheadline)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct SwapDetailView: View {
    let swapId: String

    @EnvironmentObject var app: AppViewModel
    @State private var swap: BoltzSwap?
    @State private var isClaiming = false

    var body: some View {
        List {
            if let swap {
                Section("Overview") {
                    SwapDetailRow(label: "ID", value: swap.id)
                    SwapDetailRow(label: "Type", value: String(describing: swap.swapType))
                    SwapDetailRow(label: "Status", value: String(describing: swap.status))
                    SwapDetailRow(label: "Network", value: String(describing: swap.network))
                }

                Section("Amounts") {
                    SwapDetailRow(label: "Amount", value: "\(swap.amountSat) sats")
                    SwapDetailRow(label: "Onchain amount", value: swap.onchainAmountSat.map { "\($0) sats" } ?? "-")
                }

                Section("Addresses") {
                    SwapDetailRow(label: "Lockup", value: swap.lockupAddress ?? "-")
                    SwapDetailRow(label: "Claim / onchain", value: swap.onchainAddress ?? "-")
                }

                if let invoice = swap.invoice {
                    Section("Lightning") {
                        SwapDetailRow(label: "Invoice", value: invoice)
                    }
                }

                Section("Transactions") {
                    SwapDetailRow(label: "Claim txid", value: swap.claimTxId ?? "-")
                    SwapDetailRow(label: "Refund txid", value: swap.refundTxId ?? "-")
                }

                Section("Recovery") {
                    SwapDetailRow(label: "Swap index", value: String(swap.swapIndex))
                    SwapDetailRow(label: "Timeout block", value: String(swap.timeoutBlockHeight))
                }

                Section("Timestamps") {
                    SwapDetailRow(label: "Created", value: formatEpochSeconds(swap.createdAt))
                }

                if swap.isClaimable {
                    Section {
                        Button {
                            claim()
                        } label: {
                            if isClaiming {
                                ProgressView()
                            } else {
                                Text("Claim now")
                            }
                        }
                        .disabled(isClaiming)
                    }
                }
            } else {
                Text("Loading...")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .navigationTitle("Swap Details")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refresh()
        }
    }

    private func refresh() async {
        do {
            swap = try await BoltzService.shared.getSwap(id: swapId)
        } catch {
            Logger.error("Failed to load swap '\(swapId)'", context: error.localizedDescription)
        }
    }

    /// Manually broadcast the claim for a reverse swap (recovery when auto-claim didn't fire).
    private func claim() {
        isClaiming = true
        Task {
            do {
                let txid = try await BoltzService.shared.claimReverseSwap(id: swapId)
                app.toast(type: .success, title: "Claim broadcast", description: txid)
                await refresh()
            } catch {
                Logger.error("Manual claim failed for '\(swapId)'", context: error.localizedDescription)
                app.toast(type: .error, title: "Claim failed", description: error.localizedDescription)
            }
            isClaiming = false
        }
    }
}

private struct SwapDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.gray)
            Spacer()
            CopyableText(text: value)
        }
    }
}

private let epochFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

private func formatEpochSeconds(_ seconds: UInt64) -> String {
    epochFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
}
