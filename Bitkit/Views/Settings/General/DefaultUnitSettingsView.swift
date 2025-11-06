import SwiftUI

struct DefaultUnitSettingsView: View {
    @EnvironmentObject var currency: CurrencyViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__general__unit_title"))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    CaptionMText(t("settings__general__unit_display"))
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(action: {
                        currency.primaryDisplay = .bitcoin
                    }) {
                        SettingsListLabel(
                            title: t("settings__general__unit_bitcoin"),
                            iconName: "b-unit",
                            rightIcon: currency.primaryDisplay == .bitcoin ? .checkmark : nil
                        )
                    }
                    .buttonStyle(PlainButtonStyle())

                    if let rate = currency.convert(sats: 1)?.currency {
                        Button(action: {
                            currency.primaryDisplay = .fiat
                        }) {
                            SettingsListLabel(
                                title: rate,
                                iconName: "globe",
                                rightIcon: currency.primaryDisplay == .fiat ? .checkmark : nil
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    BodyMText(t("settings__general__unit_note", variables: ["currency": currency.selectedCurrency]))
                        .padding(.vertical, 16)
                }

                VStack(alignment: .leading, spacing: 8) {
                    CaptionMText(t("settings__general__denomination_label"))
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach(BitcoinDisplayUnit.allCases, id: \.self) { unit in
                        Button(action: {
                            currency.displayUnit = unit
                        }) {
                            SettingsListLabel(
                                title: t("settings__general__denomination_\(unit.rawValue)"),
                                rightIcon: currency.displayUnit == unit ? .checkmark : nil
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .accessibilityIdentifier(unit.testIdentifier)
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
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
