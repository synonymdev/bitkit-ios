import SwiftUI

/// The Spark wallet as a connection: shown once it holds a balance or a deposit, and always on regtest so testers
/// reach its deposit address to fund it from the faucet.
struct SparkConnectionRow: View {
    @EnvironmentObject var navigation: NavigationViewModel

    private let spark = SparkManager.shared

    static var isVisible: Bool {
        let spark = SparkManager.shared
        return spark.isReady && (spark.balanceSats > 0 || !spark.deposits.isEmpty || Env.network == .regtest)
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
                    capacity: spark.balanceSats,
                    localBalance: spark.balanceSats,
                    remoteBalance: 0,
                    status: .open
                )
                .padding(.bottom, 16)

                ForEach(spark.deposits.filter { !$0.isClaimed }) { deposit in
                    SparkDepositRow(deposit: deposit)
                        .padding(.bottom, 16)
                }

                CustomDivider()
            }
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityIdentifier("SparkConnection")
    }
}

/// A deposit into Spark with its amount, confirmations while pending, and a link to its transaction.
struct SparkDepositRow: View {
    @Environment(\.openURL) private var openURL

    let deposit: SparkDeposit

    var body: some View {
        Button {
            if let url = URL(string: "\(Env.blockExplorerUrl)/tx/\(deposit.txid)") {
                openURL(url)
            }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    CaptionBText(t("lightning__spark_deposit"), textColor: .textPrimary)
                    CaptionBText(deposit.txid)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    MoneyText(sats: Int(deposit.amountSats), size: .captionB, symbol: true)
                    if let confirmations = deposit.confirmations {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__spark"))
                .padding(.bottom, 16)

            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        LightningChannel(
                            capacity: spark.balanceSats,
                            localBalance: spark.balanceSats,
                            remoteBalance: 0,
                            status: .open
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
                                amountRow(label: t("lightning__spending_label"), amount: spark.balanceSats)
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
                        .disabled(spark.balanceSats == 0)
                        .accessibilityIdentifier("SparkTransferToSavings")
                    }
                    .frame(minHeight: geometry.size.height)
                    .bottomSafeAreaPadding()
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
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
