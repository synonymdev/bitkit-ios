import SwiftUI

struct DefaultUnitSettingsView: View {
    @EnvironmentObject var currency: CurrencyViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                CaptionText(t("settings__general__unit_display").uppercased())
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
            .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 8) {
                CaptionText(t("settings__general__denomination_label").uppercased())
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(BitcoinDisplayUnit.allCases, id: \.self) { unit in
                    Button(action: {
                        currency.displayUnit = unit
                    }) {
                        SettingsListLabel(
                            title: "\(unit.display) (\(unit == .modern ? "₿ 10 000" : "₿ 0.00010000"))",
                            rightIcon: currency.displayUnit == unit ? .checkmark : nil
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
        }
        .navigationTitle(t("settings__general__unit_title"))
    }
}

// Helper for conditional modifiers
extension View {
    @ViewBuilder func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
