import SwiftUI

/// The Arkade wallet as a connection: shown once it holds a balance or a deposit, and always on regtest so testers
/// reach its deposit address to fund it from the mutinynet faucet.
struct ArkadeConnectionRow: View {
    @EnvironmentObject var navigation: NavigationViewModel

    private let arkade = ArkadeManager.shared

    static var isVisible: Bool {
        let arkade = ArkadeManager.shared
        return arkade.isReady && (arkade.balanceSats > 0 || !arkade.deposits.isEmpty || Env.network == .regtest)
    }

    var body: some View {
        Button {
            navigation.navigate(.arkadeConnectionDetail)
        } label: {
            VStack(spacing: 0) {
                HStack {
                    SubtitleText(t("lightning__arkade_provider_value"))
                    Spacer()
                    Image("chevron")
                        .resizable()
                        .foregroundColor(.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .padding(.bottom, 6)

                LightningChannel(
                    capacity: arkade.balanceSats,
                    localBalance: arkade.balanceSats,
                    remoteBalance: 0,
                    status: .open,
                    showReceiving: false
                )
                .padding(.bottom, 16)

                ForEach(arkade.deposits.filter { !$0.isClaimed }) { deposit in
                    ArkadeDepositRow(deposit: deposit)
                        .padding(.bottom, 16)
                }

                CustomDivider()
            }
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityIdentifier("ArkadeConnection")
    }
}

/// A deposit into Arkade or a withdrawal out of it, with its amount, confirmations while pending, and a link to
/// its transaction.
struct ArkadeDepositRow: View {
    @Environment(\.openURL) private var openURL

    let title: String
    let txid: String
    let amountSats: UInt64
    var confirmations: UInt32?

    init(deposit: ArkadeDeposit) {
        title = t("lightning__arkade_deposit")
        txid = deposit.txid
        amountSats = deposit.amountSats
        confirmations = deposit.confirmations
    }

    init(withdrawal: ArkadeWithdrawal) {
        title = t("wallet__activity_transfer_to_savings")
        txid = withdrawal.txid
        amountSats = withdrawal.amountSats
    }

    var body: some View {
        Button {
            if let url = URL(string: "\(Env.blockExplorerUrl)/tx/\(txid)") {
                openURL(url)
            }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    CaptionBText(title, textColor: .textPrimary)
                    CaptionBText(txid)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    MoneyText(sats: Int(amountSats), size: .captionB, symbol: true)
                    if let confirmations {
                        CaptionBText(
                            t("lightning__arkade_confirmations", variables: ["count": "\(min(confirmations, 1))"]),
                            textColor: .purpleAccent
                        )
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityIdentifier("ArkadeDeposit")
    }
}

struct ArkadeConnectionDetailView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    @State private var depositAddress: String?

    private let arkade = ArkadeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__arkade"))
                .padding(.bottom, 16)

            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        LightningChannel(
                            capacity: arkade.balanceSats,
                            localBalance: arkade.balanceSats,
                            remoteBalance: 0,
                            status: .open,
                            showReceiving: false
                        )
                        .padding(.bottom, 28)

                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 0) {
                                CustomDivider()
                                SettingsSectionHeader(t("lightning__arkade_provider"))
                                detailRow(label: t("lightning__arkade_provider"), value: t("lightning__arkade_provider_value"))
                                BodySText(t("lightning__arkade_trust"))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.top, 12)

                                if let depositAddress {
                                    Button {
                                        copy(depositAddress)
                                    } label: {
                                        detailRow(label: t("wallet__activity_address"), value: depositAddress)
                                            .contentShape(.rect)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .accessibilityIdentifier("ArkadeDepositAddress")
                                }
                            }

                            VStack(alignment: .leading, spacing: 0) {
                                SettingsSectionHeader(t("lightning__balance"))
                                amountRow(label: t("lightning__spending_label"), amount: arkade.balanceSats)

                                if let lightningAddress = arkade.lightningAddress {
                                    Button {
                                        copy(lightningAddress)
                                    } label: {
                                        detailRow(label: t("lightning__arkade_lightning_address"), value: lightningAddress)
                                            .contentShape(.rect)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .accessibilityIdentifier("ArkadeLightningAddress")
                                }

                                if let nextExpiryAt = arkade.nextExpiryAt {
                                    detailRow(label: t("lightning__arkade_expiry"), value: Self.renewalText(expiresAt: nextExpiryAt))
                                        .accessibilityIdentifier("ArkadeNextRenewal")
                                }
                            }

                            let pending = arkade.deposits.filter { !$0.isClaimed }
                            if !pending.isEmpty {
                                VStack(alignment: .leading, spacing: 16) {
                                    SettingsSectionHeader(t("lightning__arkade_deposits_pending"))
                                    ForEach(pending) { ArkadeDepositRow(deposit: $0) }
                                }
                            }

                            let claimed = arkade.deposits.filter(\.isClaimed)
                            if !claimed.isEmpty {
                                VStack(alignment: .leading, spacing: 0) {
                                    SettingsSectionHeader(t("lightning__arkade_deposits_claimed"))
                                    ForEach(claimed) { deposit in
                                        ArkadeDepositRow(deposit: deposit)
                                            .padding(.bottom, 8)
                                    }
                                }
                            }

                            if !arkade.withdrawals.isEmpty {
                                VStack(alignment: .leading, spacing: 0) {
                                    SettingsSectionHeader(t("lightning__savings_confirm__label"))
                                    ForEach(arkade.withdrawals) { withdrawal in
                                        ArkadeDepositRow(withdrawal: withdrawal)
                                            .padding(.bottom, 8)
                                        amountRow(label: t("wallet__activity_fee"), amount: withdrawal.feeSats)
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 32)

                        Spacer(minLength: 0)

                        CustomButton(title: t("lightning__transfer_to_savings_button")) {
                            if app.hasSeenTransferToSavingsIntro {
                                navigation.navigate(.savingsAvailability)
                            } else {
                                navigation.navigate(.savingsIntro)
                            }
                        }
                        .disabled(arkade.balanceSats == 0)
                        .accessibilityIdentifier("ArkadeTransferToSavings")
                    }
                    .frame(minHeight: geometry.size.height)
                    .bottomSafeAreaPadding()
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .refreshable {
            await arkade.refreshState()
        }
        .task {
            await loadDepositAddress()
        }
    }

    /// On regtest, shows Arkade's boarding address so testers can fund Arkade from the mutinynet faucet, since regtest
    /// Savings can't pay a mutinynet address.
    private func loadDepositAddress() async {
        guard Env.network == .regtest else { return }
        do {
            depositAddress = try await arkade.depositAddress()
        } catch {
            Logger.warn("Failed to load Arkade deposit address: \(error)", context: "ArkadeConnectionDetailView")
        }
    }

    /// The wallet renews outputs this long before their batch expires.
    private static let renewalLeadSeconds: UInt64 = 3 * 24 * 60 * 60

    private static func renewalText(expiresAt: UInt64) -> String {
        let renewAt = Date(timeIntervalSince1970: TimeInterval(expiresAt - min(expiresAt, renewalLeadSeconds)))
        return renewAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        Haptics.play(.copiedToClipboard)
        app.toast(type: .success, title: t("common__copied"), description: text)
    }

    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                CaptionBText(label, textColor: .textPrimary)
                Spacer()
                CaptionBText(value, textColor: .textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(height: 50)
            CustomDivider()
        }
    }

    private func amountRow(label: String, amount: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                CaptionBText(label, textColor: .textPrimary)
                Spacer()
                MoneyText(sats: Int(amount), size: .captionB, symbol: true)
            }
            .frame(height: 50)
            CustomDivider()
        }
    }
}
