import SwiftUI

struct TransferLearnMoreView: View {
    @Environment(SparkTransferFlow.self) private var flow
    @Environment(\.dismiss) var dismiss

    private let spark = SparkManager.shared

    /// The spending balance once Spark adds this transfer at the selected speed.
    private var spendingAfterSats: UInt64 {
        spark.balanceSats.saturatingAdd(flow.quote?.toSpendingSats(for: flow.speed) ?? flow.amountSats)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    DisplayText(t("lightning__spark_learn__title"), accentColor: .purpleAccent)
                        .padding(.bottom, 16)

                    BodyMText(t("lightning__spark_learn__text"))
                        .padding(.bottom, 16)

                    BodyMText(t("lightning__spark_trust"))
                }
                .padding(.bottom, 16)
            }

            VStack(alignment: .leading, spacing: 16) {
                SubtitleText(t("lightning__spark_learn__label"))
                LightningChannel(
                    capacity: spendingAfterSats,
                    localBalance: spendingAfterSats,
                    remoteBalance: 0,
                    status: .open,
                    showLabels: true,
                    showReceiving: false
                )
            }

            CustomButton(title: t("common__understood")) {
                dismiss()
            }
            .padding(.top, 32)
            .accessibilityIdentifier("LiquidityContinue")
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }
}

#Preview {
    NavigationStack {
        TransferLearnMoreView()
            .environmentObject(CurrencyViewModel())
            .environmentObject(SettingsViewModel.shared)
            .environment(SparkTransferFlow(amountSats: 100_000))
    }
    .preferredColorScheme(.dark)
}
