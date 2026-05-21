import BitkitCore
import SwiftUI

/// Three-step send transaction flow: Compose → Review → Signed/Broadcast.
/// Embedded in TrezorBalanceLookupView when an xpub lookup has balance > 0.
struct SendTransactionSection: View {
    @Binding var sendAddress: String
    @Binding var sendAmountSats: String
    @Binding var sendFeeRate: String
    let isSendMax: Bool
    let coinSelection: CoinSelection
    let sendStep: SendStep
    let isComposing: Bool
    let isOperating: Bool
    let isBroadcasting: Bool
    let isDeviceConnected: Bool
    let composeResult: ComposeResult?
    let signedTxResult: TrezorSignedTx?
    let broadcastTxid: String?
    let sendError: String?

    let onToggleSendMax: () -> Void
    let onCoinSelectionChange: (CoinSelection) -> Void
    let onCompose: () -> Void
    let onSign: () -> Void
    let onBroadcast: () -> Void
    let onBack: () -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Send Transaction")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            switch sendStep {
            case .form:
                ComposeFormView(
                    sendAddress: $sendAddress,
                    sendAmountSats: $sendAmountSats,
                    sendFeeRate: $sendFeeRate,
                    isSendMax: isSendMax,
                    coinSelection: coinSelection,
                    isComposing: isComposing,
                    onToggleSendMax: onToggleSendMax,
                    onCoinSelectionChange: onCoinSelectionChange,
                    onCompose: onCompose
                )

            case .review:
                if let composeResult {
                    ReviewSectionView(
                        result: composeResult,
                        isDeviceConnected: isDeviceConnected,
                        isSigning: isOperating,
                        onSign: onSign,
                        onBack: onBack
                    )
                }

            case .signed:
                if let signedTxResult {
                    SignedResultSectionView(
                        signedTx: signedTxResult,
                        isBroadcasting: isBroadcasting,
                        broadcastTxid: broadcastTxid,
                        onBroadcast: onBroadcast,
                        onReset: onReset
                    )
                }
            }

            if let sendError {
                TrezorErrorBanner(message: sendError)
            }
        }
    }
}

// MARK: - Compose Form

private struct ComposeFormView: View {
    @Binding var sendAddress: String
    @Binding var sendAmountSats: String
    @Binding var sendFeeRate: String
    let isSendMax: Bool
    let coinSelection: CoinSelection
    let isComposing: Bool
    let onToggleSendMax: () -> Void
    let onCoinSelectionChange: (CoinSelection) -> Void
    let onCompose: () -> Void
    @FocusState private var isFieldFocused: Bool

    private var isDisabled: Bool {
        let addressEmpty = sendAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let amountEmpty = sendAmountSats.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return addressEmpty || (!isSendMax && amountEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Destination address
            VStack(alignment: .leading, spacing: 4) {
                Text("Destination address")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))

                SwiftUI.TextField("Enter address...", text: $sendAddress, axis: .vertical)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(3)
                    .focused($isFieldFocused)
                    .padding(12)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Amount + MAX toggle
            VStack(alignment: .leading, spacing: 4) {
                Text("Amount (sats)")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))

                HStack(spacing: 8) {
                    SwiftUI.TextField(isSendMax ? "MAX" : "Amount in sats", text: $sendAmountSats)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white)
                        .keyboardType(.numberPad)
                        .focused($isFieldFocused)
                        .disabled(isSendMax)
                        .padding(12)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Button(action: onToggleSendMax) {
                        Text("MAX")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(isSendMax ? .blue : .white.opacity(0.4))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .background((isSendMax ? Color.blue : Color.white.opacity(0.3)).opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            // Fee rate
            VStack(alignment: .leading, spacing: 4) {
                Text("Fee rate (sat/vB)")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))

                SwiftUI.TextField("Fee rate", text: $sendFeeRate)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white)
                    .keyboardType(.numberPad)
                    .focused($isFieldFocused)
                    .padding(12)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Coin selection strategy
            VStack(alignment: .leading, spacing: 6) {
                Text("Coin Selection")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))

                CoinSelectionPicker(
                    selected: coinSelection,
                    onChange: onCoinSelectionChange
                )
            }

            // Compose button
            Button(action: {
                isFieldFocused = false
                onCompose()
            }) {
                HStack(spacing: 8) {
                    if isComposing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .black))
                    }
                    Text(isComposing ? "Composing..." : "Compose Transaction")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isDisabled || isComposing)
            .opacity(isDisabled || isComposing ? 0.5 : 1.0)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    isFieldFocused = false
                }
            }
        }
    }
}

// MARK: - Coin Selection Picker

private struct CoinSelectionPicker: View {
    let selected: CoinSelection
    let onChange: (CoinSelection) -> Void

    private let strategies: [(CoinSelection, String)] = [
        (.branchAndBound, "Branch & Bound"),
        (.largestFirst, "Largest First"),
        (.oldestFirst, "Oldest First"),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(strategies, id: \.0) { strategy, label in
                let isSelected = strategy == selected
                let color: Color = isSelected ? .blue : .white.opacity(0.3)

                Button(action: { onChange(strategy) }) {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(color.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}

// MARK: - Review Section

private struct ReviewSectionView: View {
    let result: ComposeResult
    let isDeviceConnected: Bool
    let isSigning: Bool
    let onSign: () -> Void
    let onBack: () -> Void

    var body: some View {
        if case let .success(psbt, fee, feeRate, totalSpent) = result {
            VStack(alignment: .leading, spacing: 12) {
                // Summary card
                VStack(spacing: 8) {
                    SendInfoRow(label: "Total Spent", value: "\(totalSpent) sats")
                    SendInfoRow(label: "Fee", value: "\(fee) sats")
                    SendInfoRow(label: "Fee Rate", value: String(format: "%.1f sat/vB", feeRate))
                }
                .padding(12)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // PSBT preview
                Text("PSBT (Base64)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))

                PSBTPreview(psbt: psbt)

                // Action buttons
                HStack(spacing: 12) {
                    Button(action: onBack) {
                        Text("Back")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    Button(action: onSign) {
                        HStack(spacing: 6) {
                            if isSigning {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .black))
                            }
                            Text(isSigning ? "Signing..." : "Sign with Trezor")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(isSigning || !isDeviceConnected)
                    .opacity(isSigning || !isDeviceConnected ? 0.5 : 1.0)
                }

                if !isDeviceConnected {
                    Text("Connect a Trezor device to sign")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
    }
}

// MARK: - PSBT Preview

private struct PSBTPreview: View {
    let psbt: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(psbt.prefix(200) + (psbt.count > 200 ? "..." : ""))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .textSelection(.enabled)
                    .lineSpacing(2)

                Spacer(minLength: 0)

                Button(action: {
                    UIPasteboard.general.string = psbt

                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copied = false
                    }
                }) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundColor(.blue)
                }
            }

            Text("\(psbt.count) characters")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Signed Result Section

private struct SignedResultSectionView: View {
    let signedTx: TrezorSignedTx
    let isBroadcasting: Bool
    let broadcastTxid: String?
    let onBroadcast: () -> Void
    let onReset: () -> Void

    @State private var copiedRawTx = false
    @State private var copiedTxid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Signature summary
            VStack(spacing: 8) {
                SendInfoRow(label: "Signatures", value: "\(signedTx.signatures.count)")
                if let txid = signedTx.txid {
                    SendInfoRow(label: "TXID", value: txid)
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Raw transaction hex
            Text("Raw Transaction Hex")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(signedTx.serializedTx)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white)
                        .textSelection(.enabled)
                        .lineSpacing(2)

                    Spacer(minLength: 0)

                    Button(action: {
                        UIPasteboard.general.string = signedTx.serializedTx
    
                        copiedRawTx = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copiedRawTx = false
                        }
                    }) {
                        Image(systemName: copiedRawTx ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundColor(.blue)
                    }
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Broadcast or result
            if let broadcastTxid {
                BroadcastResultCard(txid: broadcastTxid)
            } else {
                Button(action: onBroadcast) {
                    HStack(spacing: 8) {
                        if isBroadcasting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .black))
                        }
                        Text(isBroadcasting ? "Broadcasting..." : "Broadcast")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isBroadcasting)
                .opacity(isBroadcasting ? 0.5 : 1.0)
            }

            // New transaction button
            Button(action: onReset) {
                Text("New Transaction")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

// MARK: - Broadcast Result Card

private struct BroadcastResultCard: View {
    let txid: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Broadcast TXID")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))

                Button(action: {
                    UIPasteboard.general.string = txid

                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copied = false
                    }
                }) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                }
            }

            Text(txid)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.blue)
                .textSelection(.enabled)
                .lineSpacing(2)
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Info Row Helper

private struct SendInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 100, alignment: .leading)

            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white)
                .textSelection(.enabled)

            Spacer()
        }
    }
}
