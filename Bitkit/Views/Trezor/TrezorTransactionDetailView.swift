import BitkitCore
import SwiftUI

/// Inline content for transaction detail lookup, used by expandable section.
struct TrezorTransactionDetailContent: View {
    @State private var xpubInput: String = ""
    @State private var txidInput: String = ""

    var body: some View {
        VStack(spacing: 24) {
            TxDetailInputSection(xpubInput: $xpubInput, txidInput: $txidInput)

            TxDetailButtonWrapper(xpubInput: xpubInput, txidInput: txidInput)

            TxDetailResultsSection()
        }
    }
}

/// Full-screen view for transaction detail lookup (used for previews).
struct TrezorTransactionDetailView: View {
    var body: some View {
        ScrollView {
            TrezorTransactionDetailContent()
                .padding(16)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Color.black)
        .navigationTitle("Transaction Detail")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Button Wrapper

/// Isolates ViewModel access for the lookup button so the parent body stays cheap.
private struct TxDetailButtonWrapper: View {
    let xpubInput: String
    let txidInput: String
    @Environment(TrezorViewModel.self) private var trezor

    private var isDisabled: Bool {
        xpubInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            txidInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        TxDetailLookupButton(isLoading: trezor.isTxDetailLoading, isDisabled: isDisabled) {
            await trezor.fetchTransactionDetail(extendedKey: xpubInput, txid: txidInput)
        }
    }
}

// MARK: - Results Section Wrapper

/// Isolates all ViewModel-dependent result UI into its own view.
private struct TxDetailResultsSection: View {
    @Environment(TrezorViewModel.self) private var trezor

    var body: some View {
        Group {
            if let detail = trezor.txDetailResult {
                TxDetailOverviewSection(detail: detail)

                TxDetailInputsSection(inputs: detail.inputs)

                TxDetailOutputsSection(outputs: detail.outputs)
            }

            if let error = trezor.txDetailError {
                TrezorErrorBanner(message: error)
            }
        }
    }
}

// MARK: - Input Section

private struct TxDetailInputSection: View {
    @Binding var xpubInput: String
    @Binding var txidInput: String
    @FocusState private var focusedField: Field?

    private enum Field {
        case xpub, txid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // xpub input
            VStack(alignment: .leading, spacing: 8) {
                Text("Extended Public Key")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))

                SwiftUI.TextField("Paste xpub/ypub/zpub/tpub...", text: $xpubInput, axis: .vertical)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(3 ... 5)
                    .focused($focusedField, equals: .xpub)
                    .padding(12)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 12) {
                    Button(action: {
                        if let clipboard = UIPasteboard.general.string {
                            xpubInput = clipboard
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.clipboard")
                            Text("Paste")
                        }
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                    }

                    if !xpubInput.isEmpty {
                        Button(action: { xpubInput = "" }) {
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

            // txid input
            VStack(alignment: .leading, spacing: 8) {
                Text("Transaction ID")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))

                SwiftUI.TextField("Paste transaction ID...", text: $txidInput)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white)
                    .focused($focusedField, equals: .txid)
                    .padding(12)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 12) {
                    Button(action: {
                        if let clipboard = UIPasteboard.general.string {
                            txidInput = clipboard
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.clipboard")
                            Text("Paste")
                        }
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                    }

                    if !txidInput.isEmpty {
                        Button(action: { txidInput = "" }) {
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
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    focusedField = nil
                }
            }
        }
    }
}

// MARK: - Lookup Button

private struct TxDetailLookupButton: View {
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
                    Image(systemName: "doc.text.magnifyingglass")
                }
                Text(isLoading ? "Fetching detail..." : "Get Transaction Detail")
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

// MARK: - Overview Section

private struct TxDetailOverviewSection: View {
    let detail: TransactionDetail
    @State private var copiedTxid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transaction Overview")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            VStack(spacing: 12) {
                // Txid with copy
                HStack(alignment: .top) {
                    Text("Txid")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(width: 110, alignment: .leading)

                    Text(detail.txid)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                        .textSelection(.enabled)
                        .lineLimit(2)

                    Spacer()

                    Button(action: {
                        UIPasteboard.general.string = detail.txid
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

                ResultRow(label: "Direction", value: directionLabel)
                ResultRow(label: "Amount", value: "\(detail.amount) sats")
                ResultRow(label: "Fee", value: detail.fee.map { "\($0) sats" } ?? "N/A")
                ResultRow(label: "Fee Rate", value: detail.feeRate.map { String(format: "%.2f sat/vB", $0) } ?? "N/A")
                ResultRow(label: "Received", value: "\(detail.received) sats")
                ResultRow(label: "Sent", value: "\(detail.sent) sats")
                ResultRow(label: "Net", value: "\(detail.net) sats")

                Divider()
                    .background(Color.white.opacity(0.1))

                ResultRow(label: "Block Height", value: detail.blockHeight.map { $0 > 0 ? "\($0)" : "Unconfirmed" } ?? "Unconfirmed")
                ResultRow(label: "Timestamp", value: formattedTimestamp)
                ResultRow(label: "Confirmations", value: "\(detail.confirmations)")

                Divider()
                    .background(Color.white.opacity(0.1))

                ResultRow(label: "Size", value: "\(detail.size) bytes")
                ResultRow(label: "Virtual Size", value: "\(detail.vsize) vbytes")
                ResultRow(label: "Weight", value: "\(detail.weight) WU")
            }
            .padding(16)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var directionLabel: String {
        switch detail.direction {
        case .sent: "SENT"
        case .received: "RECEIVED"
        case .selfTransfer: "SELF TRANSFER"
        }
    }

    private var formattedTimestamp: String {
        if let timestamp = detail.timestamp, timestamp > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        return "Pending"
    }
}

// MARK: - Inputs Section

private struct TxDetailInputsSection: View {
    let inputs: [TxDetailInput]

    var body: some View {
        if !inputs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Inputs (\(inputs.count))")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))

                LazyVStack(spacing: 8) {
                    ForEach(Array(inputs.enumerated()), id: \.offset) { index, input in
                        TxInputRow(index: index, input: input)
                    }
                }
            }
        }
    }
}

private struct TxInputRow: View {
    let index: Int
    let input: TxDetailInput
    @State private var copiedTxid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Input #\(index)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            // Txid:vout
            HStack(spacing: 4) {
                Text(truncatedTxid)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))

                Text(":\(input.vout)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))

                Spacer()

                Button(action: {
                    UIPasteboard.general.string = input.txid
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

            // Sequence
            Text("Sequence: \(input.sequence)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))

            // ScriptSig
            if !input.scriptSig.isEmpty {
                Text("ScriptSig: \(input.scriptSig)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            // Witness
            if !input.witness.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Witness (\(input.witness.count) items)")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))

                    ForEach(Array(input.witness.enumerated()), id: \.offset) { _, item in
                        Text(item)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.3))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var truncatedTxid: String {
        let txid = input.txid
        if txid.count > 16 {
            return "\(txid.prefix(8))...\(txid.suffix(8))"
        }
        return txid
    }
}

// MARK: - Outputs Section

private struct TxDetailOutputsSection: View {
    let outputs: [TxDetailOutput]

    var body: some View {
        if !outputs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Outputs (\(outputs.count))")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))

                LazyVStack(spacing: 8) {
                    ForEach(Array(outputs.enumerated()), id: \.offset) { index, output in
                        TxOutputRow(index: index, output: output)
                    }
                }
            }
        }
    }
}

private struct TxOutputRow: View {
    let index: Int
    let output: TxDetailOutput

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Output index + isMine badge
            HStack {
                Text("Output #\(index)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))

                if output.isMine {
                    Text("MINE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15))
                        .clipShape(Capsule())
                }

                Spacer()

                Text("\(output.value) sats")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
            }

            // Address
            if let address = output.address, !address.isEmpty {
                Text(address)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            // ScriptPubkey
            Text("scriptPubkey: \(output.scriptPubkey)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.3))
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
                .frame(width: 110, alignment: .leading)

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
    struct TrezorTransactionDetailView_Previews: PreviewProvider {
        static var previews: some View {
            NavigationStack {
                TrezorTransactionDetailView()
            }
            .environment(TrezorViewModel())
        }
    }
#endif
