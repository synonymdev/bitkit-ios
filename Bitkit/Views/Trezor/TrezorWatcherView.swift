import BitkitCore
import SwiftUI

/// Inline content for the on-chain event watcher, used by an expandable section.
/// Subscribes an extended public key to live Electrum updates (no device required).
struct TrezorWatcherContent: View {
    @Environment(TrezorViewModel.self) private var trezor

    var body: some View {
        @Bindable var trezor = trezor
        let isStartDisabled = trezor.isStartingWatcher || trezor.watcherExtendedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        VStack(spacing: 20) {
            // Extended key input
            VStack(alignment: .leading, spacing: 8) {
                CaptionMText("Extended Key (xpub/tpub/...)")

                TextField(
                    "xpub...",
                    text: $trezor.watcherExtendedKey,
                    font: .system(size: 13, design: .monospaced),
                    axis: .vertical,
                    testIdentifier: "TrezorWatcherExtendedKey"
                )
                .lineLimit(1 ... 3)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Use xpub from device shortcut
            if trezor.xpub != nil {
                CustomButton(title: "Use xpub from device", variant: .secondary, size: .small) {
                    trezor.populateWatcherFromXpub()
                }
                .accessibilityIdentifier("TrezorWatcherUseXpub")
            }

            TrezorAccountTypeSelector(selection: $trezor.onchainAccountTypeSelection)

            // Gap limit
            VStack(alignment: .leading, spacing: 8) {
                CaptionMText("Gap Limit")

                TextField(
                    "20",
                    text: $trezor.watcherGapLimit,
                    font: .system(size: 14, design: .monospaced),
                    testIdentifier: "TrezorWatcherGapLimit"
                )
                .keyboardType(.numberPad)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Start / Stop button
            if trezor.activeWatcherId != nil {
                CustomButton(
                    title: "Stop Watching",
                    variant: .secondary,
                    isDisabled: trezor.isStartingWatcher
                ) {
                    trezor.stopWatcher()
                }
                .accessibilityIdentifier("TrezorWatcherStop")
            } else {
                CustomButton(
                    title: "Start Watching",
                    icon: Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundColor(.textPrimary),
                    isDisabled: isStartDisabled,
                    isLoading: trezor.isStartingWatcher
                ) {
                    await trezor.startWatcher()
                }
                .accessibilityIdentifier("TrezorWatcherStart")
            }

            if let error = trezor.watcherError {
                TrezorErrorBanner(message: error)
            }

            // Live status
            if trezor.hasVisibleWatcherStatus {
                WatcherStatusView(trezor: trezor)
            }
        }
    }
}

// MARK: - Status

private struct WatcherStatusView: View {
    let trezor: TrezorViewModel

    private var statusLabel: String {
        switch trezor.watcherConnectionStatus {
        case .idle: return "IDLE"
        case .starting: return "STARTING"
        case .connected: return "CONNECTED"
        case .disconnected: return "DISCONNECTED"
        case .error: return "ERROR"
        }
    }

    private var statusColor: Color {
        switch trezor.watcherConnectionStatus {
        case .idle: return .white64
        case .starting: return .yellowAccent
        case .connected: return .greenAccent
        case .disconnected: return .yellowAccent
        case .error: return .redAccent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status badge
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                CaptionBText(statusLabel, textColor: statusColor)
            }
            .accessibilityIdentifier("TrezorWatcherStatus")

            // Balance card
            if let balance = trezor.watcherBalance {
                VStack(spacing: 8) {
                    InfoRow(label: "Confirmed", value: "\(balance.confirmed) sats")
                    InfoRow(label: "Pending", value: "\(balance.trustedPending + balance.untrustedPending) sats")
                    InfoRow(label: "Total", value: "\(balance.total) sats")
                    InfoRow(label: "Block Height", value: "\(trezor.watcherBlockHeight)")
                    InfoRow(label: "Account Type", value: accountTypeLabel(trezor.watcherAccountType))
                    InfoRow(label: "Transactions", value: "\(trezor.watcherTransactionCount)")
                }
                .padding(16)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            // Transactions
            if !trezor.watcherTransactions.isEmpty {
                CaptionMText("Transactions (\(trezor.watcherTransactions.count))")

                VStack(spacing: 4) {
                    ForEach(Array(trezor.watcherTransactions.enumerated()), id: \.offset) { _, tx in
                        WatcherTransactionRow(tx: tx)
                    }
                }
            }

            // Event log
            if !trezor.watcherEvents.isEmpty {
                CaptionMText("Event Log")

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(trezor.watcherEvents.enumerated()), id: \.offset) { _, event in
                        Text(event)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white80)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accountTypeLabel(_ type: AccountType?) -> String {
        guard let type else { return "-" }
        switch type {
        case .legacy: return "legacy"
        case .wrappedSegwit: return "wrapped-segwit"
        case .nativeSegwit: return "native-segwit"
        case .taproot: return "taproot"
        }
    }
}

private struct WatcherTransactionRow: View {
    let tx: HistoryTransaction

    private var directionLabel: String {
        switch tx.direction {
        case .sent: return "Sent"
        case .received: return "Recv"
        case .selfTransfer: return "Self"
        }
    }

    private var directionColor: Color {
        switch tx.direction {
        case .sent: return .redAccent
        case .received: return .greenAccent
        case .selfTransfer: return .white64
        }
    }

    private var shortTxid: String {
        guard tx.txid.count > 16 else { return tx.txid }
        return "\(tx.txid.prefix(8))...\(tx.txid.suffix(8))"
    }

    var body: some View {
        HStack {
            CaptionText("\(directionLabel) \(tx.amount) sats", textColor: directionColor)
            Spacer()
            Text(shortTxid)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white50)
        }
        .padding(.vertical, 2)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            CaptionText(label)
            Spacer()
            CaptionBText(value, textColor: .textPrimary)
        }
    }
}
