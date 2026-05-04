import BitkitCore
import SwiftUI

/// Inline content for transaction history lookup, used by expandable section.
struct TrezorTransactionHistoryContent: View {
    @State private var input: String = ""

    var body: some View {
        VStack(spacing: 24) {
            TxHistoryInputSection(input: $input)

            TxHistoryButtonWrapper(input: input)

            TxHistoryResultsSection()
        }
    }
}

/// Full-screen view for transaction history lookup (used for previews).
struct TrezorTransactionHistoryView: View {
    var body: some View {
        ScrollView {
            TrezorTransactionHistoryContent()
                .padding(16)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Color.black)
        .navigationTitle("Transaction History")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Button Wrapper

/// Isolates ViewModel access for the lookup button so the parent body stays cheap.
private struct TxHistoryButtonWrapper: View {
    let input: String
    @Environment(TrezorViewModel.self) private var trezor

    var body: some View {
        TxHistoryLookupButton(isLoading: trezor.isTxHistoryLoading, isDisabled: input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            await trezor.fetchTransactionHistory(extendedKey: input)
        }
    }
}

// MARK: - Results Section Wrapper

/// Isolates all ViewModel-dependent result UI into its own view.
private struct TxHistoryResultsSection: View {
    @Environment(TrezorViewModel.self) private var trezor

    var body: some View {
        Group {
            if let result = trezor.txHistoryResult {
                TxHistorySummarySection(result: result)

                TxHistoryListSection(transactions: result.transactions)
            }

            if let error = trezor.txHistoryError {
                TrezorErrorBanner(message: error)
            }
        }
    }
}

// MARK: - Input Section

private struct TxHistoryInputSection: View {
    @Binding var input: String
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Extended Public Key")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            SwiftUI.TextField("Paste xpub/ypub/zpub/tpub...", text: $input, axis: .vertical)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(3 ... 5)
                .focused($isInputFocused)
                .padding(12)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") {
                            isInputFocused = false
                        }
                    }
                }

            HStack(spacing: 12) {
                Button(action: {
                    if let clipboard = UIPasteboard.general.string {
                        input = clipboard
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.clipboard")
                        Text("Paste")
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                }

                if !input.isEmpty {
                    Button(action: { input = "" }) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle")
                            Text("Clear")
                        }
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                    }
                }
            }
        }
    }
}

// MARK: - Lookup Button

private struct TxHistoryLookupButton: View {
    let isLoading: Bool
    let isDisabled: Bool
    let action: () async -> Void

    var body: some View {
        Button(action: {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            Task { await action() }
        }) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .black))
                } else {
                    Image(systemName: "list.bullet.rectangle")
                }
                Text(isLoading ? "Fetching history..." : "Get Transaction History")
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isDisabled || isLoading)
        .opacity(isDisabled ? 0.5 : 1.0)
    }
}

// MARK: - Summary Section

private struct TxHistorySummarySection: View {
    let result: TransactionHistoryResult

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Summary")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            VStack(spacing: 12) {
                ResultRow(label: "Transactions", value: "\(result.txCount)")
                ResultRow(label: "Block Height", value: "\(result.blockHeight)")
                ResultRow(label: "Account Type", value: accountTypeLabel(result.accountType))

                Divider()
                    .background(Color.white.opacity(0.1))

                ResultRow(label: "Confirmed", value: "\(result.balance.confirmed) sats")
                ResultRow(label: "Trusted Pending", value: "\(result.balance.trustedPending) sats")
                ResultRow(label: "Untrusted Pending", value: "\(result.balance.untrustedPending) sats")
                ResultRow(label: "Spendable", value: "\(result.balance.spendable) sats")
                ResultRow(label: "Total", value: "\(result.balance.total) sats")
            }
            .padding(16)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func accountTypeLabel(_ type: AccountType) -> String {
        switch type {
        case .legacy: "Legacy (BIP44 / P2PKH)"
        case .wrappedSegwit: "Wrapped SegWit (BIP49 / P2SH-P2WPKH)"
        case .nativeSegwit: "Native SegWit (BIP84 / P2WPKH)"
        case .taproot: "Taproot (BIP86 / P2TR)"
        }
    }
}

// MARK: - Transaction List Section

private struct TxHistoryListSection: View {
    let transactions: [HistoryTransaction]

    var body: some View {
        if !transactions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Transactions (\(transactions.count))")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))

                LazyVStack(spacing: 8) {
                    ForEach(Array(transactions.enumerated()), id: \.offset) { _, tx in
                        TxHistoryRow(tx: tx)
                    }
                }
            }
        }
    }
}

// MARK: - Transaction History Row

private struct TxHistoryRow: View {
    let tx: HistoryTransaction
    @State private var copiedTxid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Direction + Amount
            HStack {
                Image(systemName: directionIcon)
                    .font(.system(size: 12))
                    .foregroundColor(directionColor)
                    .frame(width: 24, height: 24)
                    .background(directionColor.opacity(0.15))
                    .clipShape(Circle())

                Text(directionLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(directionColor)

                Spacer()

                Text("\(amountPrefix)\(tx.amount) sats")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(directionColor)
            }

            // Fee
            HStack {
                Text("Fee: \(tx.fee.map { "\($0)" } ?? "N/A") sats")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))

                Spacer()

                // Confirmations badge
                if tx.confirmations > 0 {
                    Text("\(tx.confirmations) conf")
                        .font(.system(size: 10))
                        .foregroundColor(.green.opacity(0.8))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.1))
                        .clipShape(Capsule())
                } else {
                    Text("unconfirmed")
                        .font(.system(size: 10))
                        .foregroundColor(.orange.opacity(0.8))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.1))
                        .clipShape(Capsule())
                }
            }

            // Txid
            HStack(spacing: 4) {
                Text(truncatedTxid)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))

                Spacer()

                Button(action: {
                    UIPasteboard.general.string = tx.txid
                    copiedTxid = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedTxid = false
                    }
                }) {
                    Image(systemName: copiedTxid ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            // Timestamp + Block height
            HStack {
                Text(formattedTimestamp)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))

                Spacer()

                if let height = tx.blockHeight, height > 0 {
                    Text("Block \(height)")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var directionIcon: String {
        switch tx.direction {
        case .sent: "arrow.up.right"
        case .received: "arrow.down.left"
        case .selfTransfer: "arrow.left.arrow.right"
        }
    }

    private var directionColor: Color {
        switch tx.direction {
        case .sent: .red
        case .received: .green
        case .selfTransfer: .blue
        }
    }

    private var directionLabel: String {
        switch tx.direction {
        case .sent: "SENT"
        case .received: "RECEIVED"
        case .selfTransfer: "SELF"
        }
    }

    private var amountPrefix: String {
        switch tx.direction {
        case .sent: "-"
        case .received: "+"
        case .selfTransfer: ""
        }
    }

    private var truncatedTxid: String {
        let txid = tx.txid
        if txid.count > 16 {
            return "\(txid.prefix(8))...\(txid.suffix(8))"
        }
        return txid
    }

    private var formattedTimestamp: String {
        if let timestamp = tx.timestamp, timestamp > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        return "Pending"
    }
}

// MARK: - Result Row

private struct ResultRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 120, alignment: .leading)

            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white)
                .textSelection(.enabled)

            Spacer()
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct TrezorTransactionHistoryView_Previews: PreviewProvider {
        static var previews: some View {
            NavigationStack {
                TrezorTransactionHistoryView()
            }
            .environment(TrezorViewModel())
        }
    }
#endif
