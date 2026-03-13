import SwiftUI

struct DefaultUnitSettingsView: View {
    @EnvironmentObject var currency: CurrencyViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__general__unit_title"))
                .padding(.horizontal, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsSectionHeader(t("settings__general__unit_display"))

                    Button(action: {
                        currency.primaryDisplay = .bitcoin
                    }) {
                        SettingsRow(
                            title: t("settings__general__unit_bitcoin"),
                            iconName: "b-unit",
                            rightIcon: currency.primaryDisplay == .bitcoin ? .checkmark : nil
                        )
                    }

                    if let rate = currency.convert(sats: 1)?.currency {
                        Button(action: {
                            currency.primaryDisplay = .fiat
                        }) {
                            SettingsRow(
                                title: rate,
                                iconName: "globe",
                                rightIcon: currency.primaryDisplay == .fiat ? .checkmark : nil
                            )
                        }
                    }

                    BodyMText(t("settings__general__unit_note", variables: ["currency": currency.selectedCurrency]))
                        .padding(.vertical, 16)

                    CustomDivider()

                    SettingsSectionHeader(t("settings__general__denomination_label"))
                        .padding(.top, 16)

                    ForEach(BitcoinDisplayUnit.allCases, id: \.self) { unit in
                        Button(action: {
                            currency.displayUnit = unit
                        }) {
                            SettingsRow(
                                title: t("settings__general__denomination_\(unit.rawValue)"),
                                rightIcon: currency.displayUnit == unit ? .checkmark : nil
                            )
                        }
                        .accessibilityIdentifier(unit.testIdentifier)
                    }
                }
                .padding(.horizontal, 16)
                .bottomSafeAreaPadding()
            }
        }
        .navigationBarHidden(true)
    }
}

private extension BitcoinDisplayUnit {
    var testIdentifier: String {
        switch self {
        case .modern: "DenominationModern"
        case .classic: "DenominationClassic"
        }
    }
}
