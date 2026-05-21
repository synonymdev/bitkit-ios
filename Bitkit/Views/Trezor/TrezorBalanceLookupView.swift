import BitkitCore
import SwiftUI

/// Inline content for balance lookup, used by expandable section.
struct TrezorBalanceLookupContent: View {
    @State private var input: String = ""

    var body: some View {
        VStack(spacing: 24) {
            InputSection(input: $input)

            LookupButtonWrapper(input: input)

            BalanceLookupResultsSection(input: input)
        }
    }
}

/// Full-screen view for looking up balance and UTXOs (used for previews).
/// Does NOT require a connected Trezor device — queries Electrum directly.
/// When an xpub lookup returns balance > 0, shows the send transaction section.
struct TrezorBalanceLookupView: View {
    var body: some View {
        ScrollView {
            TrezorBalanceLookupContent()
                .padding(16)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Color.black)
        .navigationTitle("Balance Lookup")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Lookup Button Wrapper

/// Isolates ViewModel access for the lookup button so the parent body stays cheap.
private struct LookupButtonWrapper: View {
    let input: String
    @Environment(TrezorViewModel.self) private var trezor

    var body: some View {
        LookupButton(isLoading: trezor.isLookupLoading, isDisabled: input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            await trezor.performLookup(input: input)
        }
    }
}

// MARK: - Results Section Wrapper

/// Isolates all ViewModel-dependent result/send UI into its own view,
/// keeping the parent body free of ViewModel property accesses.
private struct BalanceLookupResultsSection: View {
    let input: String
    @Environment(TrezorViewModel.self) private var trezor

    private var hasResults: Bool {
        trezor.accountResult != nil || trezor.addressResult != nil
    }

    var body: some View {
        @Bindable var trezor = trezor
        Group {
            if let accountResult = trezor.accountResult {
                AccountResultSection(result: accountResult)
            }

            if let addressResult = trezor.addressResult {
                AddressResultSection(result: addressResult)
            }

            if hasResults {
                UTXOListSection(utxos: trezor.accountResult?.account.utxo ?? trezor.addressResult?.utxos ?? [])
            }

            // Show send transaction section when xpub has balance
            if let accountResult = trezor.accountResult, accountResult.balance > 0 {
                SendTransactionSection(
                    sendAddress: $trezor.sendAddress,
                    sendAmountSats: $trezor.sendAmountSats,
                    sendFeeRate: $trezor.sendFeeRate,
                    isSendMax: trezor.isSendMax,
                    coinSelection: trezor.coinSelection,
                    sendStep: trezor.sendStep,
                    isComposing: trezor.isComposing,
                    isOperating: trezor.isOperating,
                    isBroadcasting: trezor.isBroadcasting,
                    isDeviceConnected: trezor.isConnected,
                    composeResult: trezor.composeResult,
                    signedTxResult: trezor.signedTxResult,
                    broadcastTxid: trezor.broadcastTxid,
                    sendError: trezor.sendError,
                    onToggleSendMax: { trezor.toggleSendMax() },
                    onCoinSelectionChange: { trezor.setCoinSelection($0) },
                    onCompose: { Task { await trezor.composeTx(extendedKey: input, accountInfo: accountResult) } },
                    onSign: { Task { await trezor.signComposedTx() } },
                    onBroadcast: { Task { await trezor.broadcastSignedTx() } },
                    onBack: { trezor.backToComposeForm() },
                    onReset: { trezor.resetSendFlow() }
                )
            }

            if let error = trezor.lookupError {
                TrezorErrorBanner(message: error)
            }
        }
    }
}

// MARK: - Input Type for sub-views

extension TrezorBalanceLookupView {
    typealias InputType = TrezorViewModel.LookupInputType
}

// MARK: - Input Section

private struct InputSection: View {
    @Binding var input: String
    @FocusState private var isInputFocused: Bool

    private var detectedType: TrezorBalanceLookupView.InputType {
        TrezorViewModel.detectInputType(input)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Address or Extended Public Key")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))

                Spacer()

                if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    TypeBadge(type: detectedType)
                }
            }

            SwiftUI.TextField("Paste address or xpub...", text: $input, axis: .vertical)
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

// MARK: - Type Badge

private struct TypeBadge: View {
    let type: TrezorBalanceLookupView.InputType

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }

    private var label: String {
        switch type {
        case .extendedKey: "XPUB"
        case .address: "ADDRESS"
        case .unknown: "UNKNOWN"
        }
    }

    private var color: Color {
        switch type {
        case .extendedKey: .blue
        case .address: .green
        case .unknown: .orange
        }
    }
}

// MARK: - Lookup Button

private struct LookupButton: View {
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
                    Image(systemName: "magnifyingglass")
                }
                Text(isLoading ? "Looking up..." : "Lookup Balance & UTXOs")
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

// MARK: - Account Result Section (xpub)

private struct AccountResultSection: View {
    let result: AccountInfoResult

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Account Info")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            VStack(spacing: 12) {
                ResultRow(label: "Balance", value: "\(result.balance) sats")
                ResultRow(label: "UTXO Count", value: "\(result.utxoCount)")
                ResultRow(label: "Account Type", value: accountTypeLabel(result.accountType))
                ResultRow(label: "Derivation Path", value: result.account.path)
                ResultRow(label: "Block Height", value: "\(result.blockHeight)")
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

// MARK: - Address Result Section

private struct AddressResultSection: View {
    let result: SingleAddressInfoResult

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Address Info")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            VStack(spacing: 12) {
                ResultRow(label: "Address", value: result.address)
                ResultRow(label: "Balance", value: "\(result.balance) sats")
                ResultRow(label: "UTXOs", value: "\(result.utxos.count)")
                ResultRow(label: "Transfers", value: "\(result.transfers)")
                ResultRow(label: "Block Height", value: "\(result.blockHeight)")
            }
            .padding(16)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
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

// MARK: - UTXO List Section

private struct UTXOListSection: View {
    let utxos: [AccountUtxo]

    var body: some View {
        if !utxos.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("UTXOs (\(utxos.count))")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))

                LazyVStack(spacing: 8) {
                    ForEach(Array(utxos.enumerated()), id: \.offset) { _, utxo in
                        UTXORow(utxo: utxo)
                    }
                }
            }
        }
    }
}

// MARK: - UTXO Row

private struct UTXORow: View {
    let utxo: AccountUtxo
    @State private var copiedTxid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Amount
            HStack {
                Text("\(utxo.amount) sats")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)

                Spacer()

                if utxo.confirmations > 0 {
                    Text("\(utxo.confirmations) conf")
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

                Text(":\(utxo.vout)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))

                Spacer()

                Button(action: {
                    UIPasteboard.general.string = utxo.txid

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

            // Address
            if !utxo.address.isEmpty {
                Text(utxo.address)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Path (for xpub lookups)
            if !utxo.path.isEmpty {
                Text(utxo.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var truncatedTxid: String {
        let txid = utxo.txid
        if txid.count > 16 {
            return "\(txid.prefix(8))...\(txid.suffix(8))"
        }
        return txid
    }
}
