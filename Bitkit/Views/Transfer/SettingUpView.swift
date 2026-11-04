import SwiftUI

struct SettingUpView: View {
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @Environment(SparkTransferFlow.self) private var flow

    /// Keep in state so we don't get a new random text on each render
    @State private var randomOkText: String = localizedRandom("common__ok_random")

    private var state: SparkClaimState {
        flow.claimState
    }

    var isTransferring: Bool {
        !state.isDone
    }

    var navTitle: String {
        isTransferring ? t("lightning__transfer__nav_title") : t("lightning__transfer_success__nav_title")
    }

    var title: String {
        isTransferring ? t("lightning__savings_progress__title") : t("lightning__transfer_success__title_spending")
    }

    var text: String {
        switch state {
        case .looking: t("lightning__spark_deposit__looking")
        case .claiming, .adding: t("lightning__spark_deposit__claimed")
        case let .repriced(feeSats): t("lightning__spark_deposit__repriced", variables: ["fee": currency.primaryAmountText(sats: feeSats)])
        case .unavailable: t("lightning__spark_deposit__instant_unavailable")
        case .later: t("lightning__spark_deposit__standard", variables: [
                "standard": "\(SparkTransferFlow.matureConfirmations)",
                "minutes": "\(SparkTransferFlow.matureMinutes)",
            ])
        case .notSeen: t("lightning__spark_deposit__not_seen")
        }
    }

    /// The speed the user chose, or Later once they chose to wait.
    var speedText: String {
        let isLater = flow.speed == .later || state == .later
        return t("lightning__setting_up_speed", variables: [
            "speed": isLater ? t("lightning__spending_confirm__later") : t("fee__instant__title"),
        ])
    }

    var buttonTitle: String {
        isTransferring ? t("lightning__setting_up_button") : randomOkText
    }

    /// Sent, seen by Spark, added to spending.
    let steps = [
        t("lightning__setting_up_step1"),
        t("lightning__setting_up_step2"),
        t("lightning__setting_up_step_spark"),
    ]

    private var currentStep: Int {
        switch state {
        case .looking, .notSeen: 1
        case .claiming, .repriced, .unavailable, .later: 2
        case .adding: 3
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: navTitle, showBackButton: false)
                .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 0) {
                DisplayText(title, accentColor: .purpleAccent)
                    .padding(.bottom, 14)
                    .layoutPriority(1)

                BodyMText(text, accentColor: .white, accentFont: Fonts.bold)
                    .layoutPriority(1)
                    .accessibilityIdentifier("SettingUpText")

                if isTransferring {
                    CaptionMText(speedText)
                        .padding(.top, 8)
                        .accessibilityIdentifier("SettingUpSpeed")
                }

                if isTransferring {
                    EllipseLoader(variant: .transfer)
                        .padding(.top, 32)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("LightningSettingUp")
                } else {
                    Image("check")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 256, height: 256)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("TransferSuccess")
                }

                Spacer()

                if isTransferring {
                    ProgressSteps(steps: steps, currentStep: currentStep)
                        .padding(.vertical, 16)
                }

                if case let .repriced(feeSats) = state {
                    repricedButtons(feeSats: feeSats)
                } else {
                    CustomButton(title: buttonTitle) {
                        navigation.reset()
                    }
                    .accessibilityIdentifier("TransferSuccess-button")
                }
            }
        }
        .navigationBarHidden(true)
        .allowSwipeBack(false)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
    }

    private func repricedButtons(feeSats: UInt64) -> some View {
        HStack(spacing: 16) {
            CustomButton(title: t("lightning__spark_deposit__wait_button"), variant: .secondary) {
                flow.waitForConfirmations()
            }
            .accessibilityIdentifier("SparkDepositWait")

            CustomButton(title: t("lightning__spark_deposit__pay", variables: ["fee": currency.primaryAmountText(sats: feeSats)])) {
                flow.payRepriced()
            }
            .accessibilityIdentifier("SparkDepositPay")
        }
    }
}

#Preview("Looking") {
    settingUpPreview(.looking)
}

#Preview("Adding") {
    settingUpPreview(.claiming)
}

#Preview("Done") {
    settingUpPreview(.adding)
}

#Preview("Repriced") {
    settingUpPreview(.repriced(feeSats: 2150))
}

#Preview("Instant unavailable") {
    settingUpPreview(.unavailable)
}

#Preview("Later") {
    settingUpPreview(.later)
}

#Preview("Not seen") {
    settingUpPreview(.notSeen)
}

@MainActor
private func settingUpPreview(_ state: SparkClaimState) -> some View {
    NavigationStack {
        SettingUpView()
            .environmentObject(CurrencyViewModel())
            .environmentObject(NavigationViewModel())
            .environment(SparkTransferFlow(amountSats: 100_000, claimState: state))
    }
    .preferredColorScheme(.dark)
}
