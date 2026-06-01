import BitkitCore
import SwiftUI

/// Inline content for the on-chain event watcher, used by an expandable section.
/// Subscribes an extended public key to live Electrum updates (no device required).
struct TrezorWatcherContent: View {
    @Environment(TrezorViewModel.self) private var trezor

    var body: some View {
        @Bindable var trezor = trezor
        VStack(spacing: 20) {
            // Extended key input
            VStack(alignment: .leading, spacing: 8) {
                Text("Extended Key (xpub/tpub/...)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))

                SwiftUI.TextField("xpub...", text: $trezor.watcherExtendedKey, axis: .vertical)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1 ... 3)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(12)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("TrezorWatcherExtendedKey")
            }

            // Use xpub from device shortcut
            if trezor.xpub != nil {
                Button(action: { trezor.populateWatcherFromXpub() }) {
                    Text("Use xpub from device")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityIdentifier("TrezorWatcherUseXpub")
            }

            // Gap limit
            VStack(alignment: .leading, spacing: 8) {
                Text("Gap Limit")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))

                SwiftUI.TextField("20", text: $trezor.watcherGapLimit)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.white)
                    .keyboardType(.numberPad)
                    .padding(12)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("TrezorWatcherGapLimit")
            }

            // Start / Stop button
            if trezor.activeWatcherId != nil {
                Button(action: { trezor.stopWatcher() }) {
                    Text("Stop Watching")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(trezor.isStartingWatcher)
                .opacity(trezor.isStartingWatcher ? 0.5 : 1.0)
                .accessibilityIdentifier("TrezorWatcherStop")
            } else {
                Button(action: { Task { await trezor.startWatcher() } }) {
                    HStack(spacing: 8) {
                        if trezor.isStartingWatcher {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .black))
                        } else {
                            Image(systemName: "dot.radiowaves.left.and.right")
                        }
                        Text(trezor.isStartingWatcher ? "Starting..." : "Start Watching")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(trezor.isStartingWatcher || trezor.watcherExtendedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(trezor.watcherExtendedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1.0)
                .accessibilityIdentifier("TrezorWatcherStart")
            }

            // Live status
            if trezor.activeWatcherId != nil {
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
        case .idle: return .white.opacity(0.5)
        case .starting: return .yellow
        case .connected: return .green
        case .disconnected: return .yellow
        case .error: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status badge
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(statusColor)
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
                Text("Transactions (\(trezor.watcherTransactions.count))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))

                VStack(spacing: 4) {
                    ForEach(Array(trezor.watcherTransactions.enumerated()), id: \.offset) { _, tx in
                        WatcherTransactionRow(tx: tx)
                    }
                }
            }

            // Event log
            if !trezor.watcherEvents.isEmpty {
                Text("Event Log")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(trezor.watcherEvents.enumerated()), id: \.offset) { _, event in
                        Text(event)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
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
        case .sent: return .red
        case .received: return .green
        case .selfTransfer: return .white.opacity(0.6)
        }
    }

    private var shortTxid: String {
        guard tx.txid.count > 16 else { return tx.txid }
        return "\(tx.txid.prefix(8))...\(tx.txid.suffix(8))"
    }

    var body: some View {
        HStack {
            Text("\(directionLabel) \(tx.amount) sats")
                .font(.system(size: 12))
                .foregroundColor(directionColor)
            Spacer()
            Text(shortTxid)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(.vertical, 2)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.6))
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
        }
    }
}
