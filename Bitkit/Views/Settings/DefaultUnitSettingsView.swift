import SwiftUI

struct DefaultUnitSettingsView: View {
    @EnvironmentObject var currency: CurrencyViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                CaptionText(NSLocalizedString("settings__general__unit_display", comment: "").uppercased())
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: {
                    currency.primaryDisplay = .bitcoin
                }) {
                    SettingsListLabel(
                        title: NSLocalizedString("settings__general__unit_bitcoin", comment: ""),
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
                            iconName: "fiat-unit",
                            rightIcon: currency.primaryDisplay == .fiat ? .checkmark : nil
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                BodyMText(localizedString("settings__general__unit_note", comment: "", variables: ["currency": currency.selectedCurrency]))
                    .padding(16)
            }

            VStack(alignment: .leading, spacing: 8) {
                CaptionText(NSLocalizedString("settings__general__denomination_label", comment: "").uppercased())
                    .padding(16)
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
        }
        .navigationTitle(NSLocalizedString("settings__general__unit_title", comment: ""))
    }
}

// Helper for conditional modifiers
extension View {
    @ViewBuilder func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
