import LDKNode
import SwiftUI

struct SendUtxoSelectionView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var activities: ActivityListViewModel
    @Binding var navigationPath: [SendRoute]

    @State private var selectedUtxos: Set<String> = []
    @State private var utxoTags: [String: [String]] = [:] // Map UTXO txid to tags

    private var totalSelectedSats: UInt64 {
        wallet.availableUtxos
            .filter { selectedUtxos.contains($0.outpoint.txid) }
            .reduce(0) { $0 + $1.valueSats }
    }

    private var totalRequiredSats: UInt64 {
        wallet.sendAmountSats ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__selection_title"), showBackButton: true)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(wallet.availableUtxos.enumerated()), id: \.element.outpoint.txid) { _, utxo in
                        UtxoRowView(
                            utxo: utxo,
                            tags: utxoTags[utxo.outpoint.txid] ?? [],
                            isSelected: selectedUtxos.contains(utxo.outpoint.txid)
                        ) { isSelected in
                            if isSelected {
                                selectedUtxos.insert(utxo.outpoint.txid)
                            } else {
                                selectedUtxos.remove(utxo.outpoint.txid)
                            }
                        }
                    }
                }
                .padding(.top, 16)
            }

            Spacer()

            // Bottom summary
            VStack(spacing: 8) {
                HStack {
                    BodyMText(t("wallet__selection_total_required").uppercased(), textColor: .textSecondary)
                    Spacer()
                    BodyMSBText("\(formatSats(totalRequiredSats))", textColor: .textPrimary)
                }
                .padding(.top, 16)

                Divider()

                HStack {
                    BodyMText(t("wallet__selection_total_selected").uppercased(), textColor: .textSecondary)
                    Spacer()
                    BodyMSBText("\(formatSats(totalSelectedSats))", textColor: totalSelectedSats >= totalRequiredSats ? .greenAccent : .redAccent)
                }
            }
            .padding(.bottom, 16)

            CustomButton(title: t("common__continue"), isDisabled: selectedUtxos.isEmpty || totalSelectedSats < totalRequiredSats) {
                do {
                    wallet.selectedUtxos = wallet.availableUtxos.filter { selectedUtxos.contains($0.outpoint.txid) }

                    navigationPath.append(.confirm)
                } catch {
                    Logger.error(error, context: "Failed to set fee rate")
                    app.toast(type: .error, title: "Send Error", description: error.localizedDescription)
                }
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 16)
        .navigationBarHidden(true)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await loadUtxoTags()
        }
    }

    private func loadUtxoTags() async {
        guard let onchainActivities = activities.onchainActivities else { return }

        // Create a map of txId to activity for efficient lookup
        let activityMap = Dictionary(
            onchainActivities.compactMap { activity in
                if case let .onchain(onchainActivity) = activity {
                    return (onchainActivity.txId, onchainActivity)
                }
                return nil
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Load tags for each UTXO that has a corresponding activity
        for utxo in wallet.availableUtxos {
            if let activity = activityMap[utxo.outpoint.txid] {
                do {
                    let tags = try await activities.getTagsForActivity(activity.id)
                    utxoTags[utxo.outpoint.txid] = tags
                } catch {
                    Logger.error(error, context: "Failed to load tags for UTXO \(utxo.outpoint.txid)")
                    utxoTags[utxo.outpoint.txid] = []
                }
            }
        }
    }

    private func formatSats(_ sats: UInt64) -> String {
        if let converted = currency.convert(sats: sats) {
            let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
            return btcComponents.value
        }
        return String(sats)
    }
}

struct UtxoRowView: View {
    let utxo: SpendableUtxo
    let tags: [String]
    let isSelected: Bool
    let onToggle: (Bool) -> Void

    @EnvironmentObject var currency: CurrencyViewModel

    var body: some View {
        VStack {
            HStack(spacing: 16) {
                // Left side - Numbers
                VStack(alignment: .leading, spacing: 4) {
                    BodyMSBText("₿ \(formatBtcAmount(utxo.valueSats))", textColor: .textPrimary)
                        .lineLimit(1)
                    BodySText("\(currency.symbol) \(formatUsdAmount(utxo.valueSats))", textColor: .textSecondary)
                        .lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)

                // Middle - Tags
                if !tags.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(tags.prefix(2)), id: \.self) { tag in
                            Tag(tag)
                        }
                    }
                }

                Spacer()

                // Right side - Toggle switch
                Toggle(
                    "",
                    isOn: .init(
                        get: { isSelected },
                        set: { onToggle($0) }
                    )
                )
                .tint(Color.brandAccent)
                .padding(.trailing, 2)
                .fixedSize()
            }
            Divider()
        }
        .padding(.vertical, 16)
    }

    private func formatBtcAmount(_ sats: UInt64) -> String {
        if let converted = currency.convert(sats: sats) {
            let btcComponents = converted.bitcoinDisplay(unit: currency.displayUnit)
            return btcComponents.value
        }
        return String(sats)
    }

    private func formatUsdAmount(_ sats: UInt64) -> String {
        if let converted = currency.convert(sats: sats) {
            return converted.formatted
        }
        return "0"
    }
}

extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

#Preview {
    VStack {}.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                NavigationStack {
                    SendAmountView(navigationPath: .constant([]))
                        .environmentObject(AppViewModel())
                        .environmentObject(WalletViewModel())
                        .environmentObject(CurrencyViewModel())
                        .environmentObject(SettingsViewModel.shared)
                }
                .presentationDetents([.height(UIScreen.screenHeight - 120)])
            }
        )
        .preferredColorScheme(.dark)
}
