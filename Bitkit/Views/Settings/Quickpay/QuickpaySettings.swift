import SwiftUI

struct QuickpaySettings: View {
    @EnvironmentObject private var settings: SettingsViewModel

    private var dailyLimitUsd: Int {
        QuickPayLimits.dailyCapUsdDisplay(
            thresholdUsd: settings.quickpayAmount,
            multiplier: settings.quickpayDailyLimitMultiplier
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__quickpay__nav_title"))
                .padding(.horizontal, 16)

            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsRow(
                            title: t("settings__quickpay__settings__toggle"),
                            toggle: $settings.enableQuickpay,
                            testIdentifier: "QuickpayToggle"
                        )

                        BodyMText(
                            t("settings__quickpay__settings__text", variables: ["amount": String(Int(settings.quickpayAmount))])
                        )
                        .padding(.top, 16)

                        VStack(alignment: .leading, spacing: 0) {
                            SettingsSectionHeader(t("settings__quickpay__settings__label"))
                            CustomSlider(
                                value: $settings.quickpayAmount,
                                steps: QuickPayLimits.thresholdSteps,
                                testIdentifier: "QuickpayAmountSlider"
                            )
                        }
                        .padding(.top, 32)

                        VStack(alignment: .leading, spacing: 0) {
                            SettingsSectionHeader(t("settings__quickpay__settings__daily_label"))

                            BodyMText(
                                t(
                                    "settings__quickpay__settings__daily_text",
                                    variables: [
                                        "limit": String(dailyLimitUsd),
                                        "multiplier": String(Int(settings.quickpayDailyLimitMultiplier)),
                                    ]
                                )
                            )
                            .padding(.bottom, 16)

                            CustomSlider(
                                value: $settings.quickpayDailyLimitMultiplier,
                                steps: QuickPayLimits.dailyMultiplierSteps,
                                formatLabel: { "\(Int($0))×" },
                                testIdentifier: "QuickpayDailyLimitSlider"
                            )
                        }
                        .padding(.top, 32)

                        VStack {
                            Spacer()

                            Image("fast-forward")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 256, maxHeight: 256)

                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)

                        BodySText(t("settings__quickpay__settings__note"))
                    }
                    .frame(minHeight: geometry.size.height)
                    .padding(.horizontal, 16)
                    .bottomSafeAreaPadding()
                }
            }
        }
        .navigationBarHidden(true)
    }
}

#Preview {
    NavigationStack {
        QuickpaySettings()
            .environmentObject(SettingsViewModel.shared)
            .preferredColorScheme(.dark)
    }
}
