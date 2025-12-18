import SwiftUI

struct QuickpaySettings: View {
    @EnvironmentObject private var settings: SettingsViewModel

    private let sliderSteps: [Double] = [1, 5, 10, 20, 50]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__quickpay__nav_title"))
                .padding(.horizontal, 16)

            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsListLabel(
                            title: t("settings__quickpay__settings__toggle"),
                            toggle: $settings.enableQuickpay,
                            testIdentifier: "QuickpayToggle"
                        )

                        BodyMText(
                            t("settings__quickpay__settings__text", variables: ["amount": String(Int(settings.quickpayAmount))])
                        )
                        .padding(.top, 16)

                        VStack(alignment: .leading, spacing: 16) {
                            CaptionMText(t("settings__quickpay__settings__label"))
                            CustomSlider(value: $settings.quickpayAmount, steps: sliderSteps)
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
                        // .padding(.vertical, 32)

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
