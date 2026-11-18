import SwiftUI

/// The Spark wallet as a connection: shown once it holds a balance or a deposit, and always on regtest so testers
/// reach its deposit address to fund it from the faucet.
struct SparkConnectionRow: View {
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var network: NetworkMonitor

    private let spark = SparkManager.shared

    static var isVisible: Bool {
        let spark = SparkManager.shared
        // An exit's progress and result stay reachable while Spark is not ready, such as with the operators down.
        let hasExit = spark.isExiting || spark.recoverableFundsSats > 0
        // An earlier exit's address stays reachable once Spark holds nothing.
        return SparkExitManager.shared.showsResult || !SparkExitManager.shared.shownEarlierAddresses.isEmpty
            || spark.isReady && (spark.shownBalanceSats > 0 || !spark.deposits.isEmpty || hasExit || Env.network == .regtest)
    }

    var body: some View {
        Button {
            navigation.navigate(.sparkConnectionDetail)
        } label: {
            VStack(spacing: 0) {
                HStack {
                    SubtitleText(t("lightning__spark_provider_value"))
                    Spacer()
                    Image("chevron")
                        .resizable()
                        .foregroundColor(.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .padding(.bottom, 6)

                SparkChannel(balanceSats: spark.shownBalanceSats, isReceiving: AppStatusHelper.isSparkReceiving(network: network))
                    .padding(.bottom, 16)

                CustomDivider()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityIdentifier("SparkConnection")
    }
}

/// Spark's balance as a channel bar: its spending balance, and receiving with no limit while Spark can receive.
private struct SparkChannel: View {
    let balanceSats: UInt64
    let isReceiving: Bool

    var body: some View {
        LightningChannel(
            capacity: balanceSats,
            localBalance: balanceSats,
            remoteBalance: 0,
            status: .open,
            showReceiving: isReceiving,
            receivingUnlimited: isReceiving
        )
    }
}

/// A withdrawal out of Spark to savings, with its amount and a link to its transaction.
struct SparkWithdrawalRow: View {
    @Environment(\.openURL) private var openURL

    let withdrawal: SparkWithdrawal

    var body: some View {
        Button {
            if let url = URL(string: "\(Env.blockExplorerUrl)/tx/\(withdrawal.txid)") {
                openURL(url)
            }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    CaptionBText(t("wallet__activity_transfer_to_savings"), textColor: .textPrimary)
                    CaptionBText(withdrawal.txid)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                MoneyText(sats: Int(withdrawal.amountSats), size: .captionB, symbol: true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityIdentifier("SparkWithdrawal")
    }
}

struct SparkConnectionDetailView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var network: NetworkMonitor
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var wallet: WalletViewModel
    @Environment(\.openURL) private var openURL

    @State private var depositAddress: String?

    private let spark = SparkManager.shared

    /// The force transfer is offered while Spark holds funds, also a kept balance while it reads 0, and leads to the
    /// transfer's progress or result while it runs or its leftover fee funding is still on its way to savings.
    private var showsExit: Bool {
        spark.shownBalanceSats > 0 || spark.recoverableFundsSats > 0 || SparkExitManager.shared.showsResult
    }

    /// Spark's connection state, worded and coloured like a channel's: open, connecting or offline.
    private var status: (text: String, color: Color) {
        switch AppStatusHelper.sparkStatus(network: network) ?? .error {
        case .ready: (t("lightning__order_state__open"), .greenAccent)
        case .pending: (t("settings__status__spark__pending"), .yellowAccent)
        case .error: (t("settings__status__spark__error"), .redAccent)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__spark_provider_value"))
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    SparkChannel(balanceSats: spark.shownBalanceSats, isReceiving: AppStatusHelper.isSparkReceiving(network: network))
                        .padding(.bottom, 16)

                    CustomDivider()

                    VStack(alignment: .leading, spacing: 0) {
                        SettingsSectionHeader(t("lightning__status"))
                        HStack(alignment: .center, spacing: 8) {
                            CircularIcon(
                                icon: "bolt",
                                iconColor: status.color,
                                backgroundColor: status.color.opacity(0.16),
                                size: 32
                            )
                            BodyMSBText(status.text, textColor: status.color)
                        }
                        .padding(.bottom, 16)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("SparkStatus")
                        CustomDivider()
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        SettingsSectionHeader(t("lightning__spark_provider"))
                        detailRow(label: t("lightning__spark"), value: t("lightning__spark_operators"))

                        if let depositAddress {
                            copyRow(label: t("wallet__activity_address"), value: depositAddress)
                                .accessibilityIdentifier("SparkDepositAddress")
                        }

                        BodyMText(t("lightning__spark_trust"), textColor: .white50)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 16)
                        CustomDivider()
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        SettingsSectionHeader(t("lightning__balance"))
                        if AppStatusHelper.isSparkReceiving(network: network) {
                            detailRow(label: t("lightning__receiving_label"), value: t("lightning__spark_receiving_unlimited"))
                        }
                        amountRow(label: t("lightning__spending_label"), amount: spark.shownBalanceSats)
                    }

                    if !spark.deposits.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            SettingsSectionHeader(t("lightning__spark_deposits"))
                            CustomDivider()
                            ForEach(spark.deposits) { deposit in
                                depositRows(deposit)
                            }
                        }
                    }

                    let earlier = SparkExitManager.shared.shownEarlierAddresses
                    if !earlier.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            SettingsSectionHeader(t("lightning__spark_exit__earlier_addresses"))
                            BodySText(t("lightning__spark_exit__earlier_addresses_text"))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 8)
                            ForEach(earlier) { entry in
                                copyRow(label: t("wallet__activity_address"), value: entry.address)
                                    .accessibilityIdentifier("SparkExitEarlierAddress")
                                copyRow(label: t("lightning__spark_exit__earlier_path"), value: entry.path)
                                    .accessibilityIdentifier("SparkExitEarlierPath")
                                if let sats = entry.sats {
                                    amountRow(label: t("lightning__balance"), amount: sats)
                                }
                            }
                            .padding(.bottom, 8)
                        }
                    }

                    if !spark.withdrawals.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            SettingsSectionHeader(t("lightning__savings_confirm__label"))
                            ForEach(spark.withdrawals) { withdrawal in
                                SparkWithdrawalRow(withdrawal: withdrawal)
                                    .padding(.vertical, 8)
                                amountRow(label: t("wallet__activity_fee"), amount: withdrawal.feeSats)
                            }
                        }
                    }
                }
                .padding(.bottom, 32)
            }

            VStack(spacing: 16) {
                CustomButton(
                    title: t("lightning__transfer_to_savings_button"),
                    icon: Image("arrow-up-down")
                        .resizable()
                        .frame(width: 16, height: 16)
                        .foregroundColor(.textPrimary)
                ) {
                    if app.hasSeenTransferToSavingsIntro {
                        navigation.navigateToTransferSavings(wallet: wallet, transfer: transfer)
                    } else {
                        navigation.navigate(.savingsIntro)
                    }
                }
                .disabled(spark.balanceSats == 0 || spark.isExiting)
                .accessibilityIdentifier("SparkTransferToSavings")

                if showsExit {
                    CustomButton(
                        title: t("lightning__spark_exit__button"),
                        variant: .secondary,
                        icon: Image("warning")
                            .resizable()
                            .frame(width: 16, height: 16)
                            .foregroundColor(.yellowAccent)
                    ) {
                        navigation.navigate(SparkExitManager.shared.showsResult ? .sparkExitProgress : .sparkExitIntro)
                    }
                    .accessibilityIdentifier("SparkEmergencyExit")
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .refreshable {
            await spark.refreshState()
            await SparkExitManager.shared.refreshEarlierAddresses()
        }
        .task {
            await loadDepositAddress()
        }
        .task {
            await SparkExitManager.shared.refreshEarlierAddresses()
        }
    }

    /// On regtest, shows Spark's deposit address so testers can fund Spark from Lightspark's regtest faucet.
    private func loadDepositAddress() async {
        guard Env.network == .regtest else { return }
        do {
            depositAddress = try await spark.depositAddress()
        } catch {
            Logger.warn("Failed to load Spark deposit address: \(error)", context: "SparkConnectionDetailView")
        }
    }

    /// A deposit's transaction, amount and claim fee, or its confirmations while Spark has not claimed it.
    private func depositRows(_ deposit: SparkDeposit) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if let url = URL(string: "\(Env.blockExplorerUrl)/tx/\(deposit.txid)") {
                    openURL(url)
                }
            } label: {
                compactRow(label: t("lightning__spark_deposit_tx")) {
                    CaptionBText(deposit.txid.ellipsis(maxLength: 16), textColor: .textPrimary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityIdentifier("SparkDeposit")

            // A claimed deposit's amount is what Spark credited after the claim fee; the row shows what was sent.
            compactRow(label: t("lightning__spark_deposit")) {
                MoneyText(sats: Int(deposit.amountSats + (deposit.isClaimed ? deposit.feeSats : 0)), size: .captionB, symbol: true)
            }

            if deposit.isClaimed {
                compactRow(label: t("lightning__spark_claim_fee")) {
                    MoneyText(sats: Int(deposit.feeSats), size: .captionB, symbol: true)
                }
            } else {
                compactRow(label: t("lightning__status")) {
                    CaptionBText(
                        deposit.confirmations.flatMap { $0 > 0 ? $0 : nil }.map {
                            t("lightning__spark_confirmations", variables: ["count": "\(min($0, 3))"])
                        } ?? t("wallet__activity_pending"),
                        textColor: .purpleAccent
                    )
                }
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { CustomDivider() }
    }

    private func compactRow(label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 16) {
            CaptionBText(label, textColor: .textPrimary)
            Spacer()
            value()
        }
        .frame(height: 34)
        .contentShape(.rect)
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

    private func copyRow(label: String, value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            Haptics.play(.copiedToClipboard)
            app.toast(type: .success, title: t("common__copied"), description: value)
        } label: {
            detailRow(label: label, value: value)
                .contentShape(.rect)
        }
        .buttonStyle(PlainButtonStyle())
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
