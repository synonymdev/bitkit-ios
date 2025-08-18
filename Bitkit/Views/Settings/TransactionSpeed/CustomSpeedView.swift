import SwiftUI

struct CustomSpeedView: View {
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var settings: SettingsViewModel

    @State private var feeRate: UInt32 = 1

    // Average transaction size for fee calculation
    private let avgTransactionSize: UInt32 = 256 // vBytes for typical transaction

    private var totalFee: UInt64 {
        return UInt64(avgTransactionSize * feeRate)
    }

    private var isValid: Bool {
        return feeRate > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CaptionMText(localizedString("common__sat_vbyte"))
                .padding(.bottom, 16)

            MoneyText(sats: Int(feeRate), symbol: true)
                .padding(.bottom, 16)

            // Total fee estimate
            if isValid {
                if let fiatAmount = currency.convert(sats: totalFee) {
                    BodyMText(
                        localizedString(
                            "settings__general__speed_fee_total_fiat",
                            variables: [
                                "feeSats": String(totalFee),
                                "fiatSymbol": fiatAmount.symbol,
                                "fiatFormatted": fiatAmount.formatted,
                            ]
                        )
                    )
                } else {
                    BodyMText(
                        localizedString(
                            "settings__general__speed_fee_total",
                            variables: [
                                "feeSats": String(totalFee),
                            ]
                        )
                    )
                }
            }

            Spacer()

            NumPad { key in
                handleNumberPadInput(key)
            }

            CustomButton(
                title: localizedString("common__continue"),
                isDisabled: !isValid
            ) {
                // Save the custom speed setting
                settings.defaultTransactionSpeed = .custom(satsPerVByte: feeRate)
                navigation.navigateBack()
            }
            .padding(.top, 16)
        }
        .navigationTitle(localizedString("settings__general__speed_fee_custom"))
        .navigationBarTitleDisplayMode(.inline)
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .onAppear {
            // Initialize from current setting if it's custom
            if case let .custom(currentRate) = settings.defaultTransactionSpeed {
                feeRate = currentRate
            }
        }
    }

    private func handleNumberPadInput(_ key: String) {
        let current = String(feeRate)

        if key == "delete" {
            if current.count > 1 {
                let newString = String(current.dropLast())
                feeRate = UInt32(newString) ?? 0
            } else {
                feeRate = 0
            }
        } else {
            // Handle leading zero
            let newString: String = if current == "0" {
                key
            } else {
                current + key
            }

            // Limit to 3 digits (max 999 sat/vB)
            if newString.count <= 3, let newRate = UInt32(newString) {
                feeRate = newRate
            }
        }
    }
}
