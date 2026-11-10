import SwiftUI

/// The Spark wallet as a connection: shown once it holds a balance or a deposit, and always on regtest so testers
/// reach its deposit address to fund it from the faucet.
struct SparkConnectionRow: View {
    @EnvironmentObject var navigation: NavigationViewModel

    private let spark = SparkManager.shared

    static var isVisible: Bool {
        let spark = SparkManager.shared
        // An exit's progress and result stay reachable while Spark is not ready, such as with the operators down.
        let hasExit = spark.isExiting || spark.recoverableFundsSats > 0
        return SparkExitManager.shared.showsResult
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

                LightningChannel(
                    capacity: spark.shownBalanceSats,
                    localBalance: spark.shownBalanceSats,
                    remoteBalance: 0,
                    status: .open,
                    showReceiving: false
                )
                .padding(.bottom, 16)

                ForEach(spark.deposits.filter { !$0.isClaimed }) { deposit in
                    SparkDepositRow(deposit: deposit)
                        .padding(.bottom, 16)
                }

                CustomDivider()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityIdentifier("SparkConnection")
    }
}

/// A deposit into Spark or a withdrawal out of it, with its amount, confirmations while pending, and a link to
/// its transaction.
struct SparkDepositRow: View {
    @Environment(\.openURL) private var openURL

    let title: String
    let txid: String
    let amountSats: UInt64
    var confirmations: UInt32?

    init(deposit: SparkDeposit) {
        title = t("lightning__spark_deposit")
        txid = deposit.txid
        amountSats = deposit.amountSats
        confirmations = deposit.confirmations
    }

    init(withdrawal: SparkWithdrawal) {
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
                            t("lightning__spark_confirmations", variables: ["count": "\(min(confirmations, 3))"]),
                            textColor: .purpleAccent
                        )
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityIdentifier("SparkDeposit")
    }
}

struct SparkConnectionDetailView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel

    @State private var depositAddress: String?

    private let spark = SparkManager.shared

    /// The emergency exit is offered while Spark holds funds, also a kept balance while it reads 0, and leads to the
    /// exit's progress or result while it runs or its leftover fee funding is still on its way to savings.
    private var showsExit: Bool {
        spark.shownBalanceSats > 0 || spark.recoverableFundsSats > 0 || SparkExitManager.shared.showsResult
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__spark"))
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    LightningChannel(
                        capacity: spark.shownBalanceSats,
                        localBalance: spark.shownBalanceSats,
                        remoteBalance: 0,
                        status: .open,
                        showReceiving: false
                    )
                    .padding(.bottom, 28)

                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 0) {
                            CustomDivider()
                            SettingsSectionHeader(t("lightning__spark_provider"))
                            detailRow(label: t("lightning__spark_provider"), value: t("lightning__spark_provider_value"))
                            BodySText(t("lightning__spark_trust"))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 12)

                            if let depositAddress {
                                Button {
                                    UIPasteboard.general.string = depositAddress
                                    Haptics.play(.copiedToClipboard)
                                    app.toast(type: .success, title: t("common__copied"), description: depositAddress)
                                } label: {
                                    detailRow(label: t("wallet__activity_address"), value: depositAddress)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .accessibilityIdentifier("SparkDepositAddress")
                            }
                        }

                        VStack(alignment: .leading, spacing: 0) {
                            SettingsSectionHeader(t("lightning__balance"))
                            amountRow(label: t("lightning__spending_label"), amount: spark.shownBalanceSats)
                        }

                        let pending = spark.deposits.filter { !$0.isClaimed }
                        if !pending.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                SettingsSectionHeader(t("lightning__spark_deposits_pending"))
                                ForEach(pending) { SparkDepositRow(deposit: $0) }
                            }
                        }

                        let claimed = spark.deposits.filter(\.isClaimed)
                        if !claimed.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                SettingsSectionHeader(t("lightning__spark_deposits_claimed"))
                                ForEach(claimed) { deposit in
                                    SparkDepositRow(deposit: deposit)
                                        .padding(.bottom, 8)
                                    amountRow(label: t("lightning__spark_claim_fee"), amount: deposit.feeSats)
                                }
                            }
                        }

                        if !spark.withdrawals.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                SettingsSectionHeader(t("lightning__savings_confirm__label"))
                                ForEach(spark.withdrawals) { withdrawal in
                                    SparkDepositRow(withdrawal: withdrawal)
                                        .padding(.bottom, 8)
                                    amountRow(label: t("wallet__activity_fee"), amount: withdrawal.feeSats)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 32)
                }
            }

            CustomButton(title: t("lightning__transfer_to_savings_button")) {
                if app.hasSeenTransferToSavingsIntro {
                    navigation.navigate(.savingsAvailability)
                } else {
                    navigation.navigate(.savingsIntro)
                }
            }
            .disabled(spark.balanceSats == 0 || spark.isExiting)
            .accessibilityIdentifier("SparkTransferToSavings")

            if showsExit {
                CustomButton(title: t("lightning__spark_exit__button"), variant: .tertiary) {
                    navigation.navigate(SparkExitManager.shared.showsResult ? .sparkExitProgress : .sparkExitIntro)
                }
                .padding(.top, 8)
                .accessibilityIdentifier("SparkEmergencyExit")
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .refreshable {
            await spark.refreshState()
        }
        .task {
            await loadDepositAddress()
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
