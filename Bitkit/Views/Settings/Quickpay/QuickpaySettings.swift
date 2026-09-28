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
                                variables: ["limit": String(dailyLimitUsd)]
                            )
                        )
                        .padding(.bottom, 16)

                        CustomSlider(
                            value: $settings.quickpayDailyLimitMultiplier,
                            steps: QuickPayLimits.dailyMultiplierSteps,
                            formatLabel: {
                                t(
                                    "settings__quickpay__settings__multiplier_format",
                                    variables: ["multiplier": String(Int($0))]
                                )
                            },
                            testIdentifier: "QuickpayDailyLimitSlider"
                        )
                    }
                    .padding(.top, 32)

                    BodySText(t("settings__quickpay__settings__note"))
                }
                .padding(.horizontal, 16)
                .bottomSafeAreaPadding()
            }
        }
        .navigationBarHidden(true)
    }
}
