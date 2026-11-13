import SwiftUI

struct QuickpaySettings: View {
    @EnvironmentObject private var settings: SettingsViewModel
    @State private var authorization = PaymentAuthorization(pinMessage: t("security__pin_quickpay"))
    /// Bumped when a change is not saved at once, so the toggle and sliders redraw at the stored values.
    @State private var controlsRevision = 0

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
                        toggle: quickpayBinding(\.enableQuickpay, change: QuickpaySettingChange.enabled),
                        testIdentifier: "QuickpayToggle"
                    )

                    BodyMText(
                        t("settings__quickpay__settings__text", variables: ["amount": String(Int(settings.quickpayAmount))])
                    )
                    .padding(.top, 16)

                    VStack(alignment: .leading, spacing: 0) {
                        SettingsSectionHeader(t("settings__quickpay__settings__label"))
                        CustomSlider(
                            value: quickpayBinding(\.quickpayAmount, change: QuickpaySettingChange.amount),
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
                            value: quickpayBinding(\.quickpayDailyLimitMultiplier, change: QuickpaySettingChange.dailyLimitMultiplier),
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
                .id(controlsRevision)
                .padding(.horizontal, 16)
                .bottomSafeAreaPadding()
            }
        }
        .navigationBarHidden(true)
        .paymentAuthorization(authorization)
    }

    private func quickpayBinding<Value: Equatable>(
        _ storedValue: KeyPath<SettingsViewModel, Value>,
        change: @escaping (Value) -> QuickpaySettingChange
    ) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: storedValue] },
            set: { newValue in
                settings.changeQuickpaySetting(change(newValue)) {
                    await authorization.authorize(settings: settings)
                }
                if settings[keyPath: storedValue] != newValue {
                    controlsRevision += 1
                }
            }
        )
    }
}
