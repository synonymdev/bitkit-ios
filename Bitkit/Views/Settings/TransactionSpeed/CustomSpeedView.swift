import SwiftUI

struct CustomSpeedView: View {
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var settings: SettingsViewModel

    @State private var feeRate: UInt32 = 0
    @State private var isPresetSelected = false

    /// Average transaction size for fee calculation
    private let avgTransactionSize: UInt32 = 256 // vBytes for typical transaction

    private var totalFee: UInt64 {
        return UInt64(avgTransactionSize * feeRate)
    }

    private var isValid: Bool {
        return feeRate > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__general__speed_fee_custom"))
                .padding(.bottom, 16)

            CaptionMText(t("common__sat_vbyte"))
                .padding(.bottom, 16)

            MoneyText(
                sats: Int(feeRate),
                forceUnit: .bitcoin,
                forceDisplayUnit: .modern,
                symbol: true,
                color: feeRate == 0 ? .textSecondary : .textPrimary,
                fillsWidth: false
            )
            .presetSelection(isPresetSelected)
            .padding(.bottom, 16)

            // Total fee estimate
            if isValid {
                if let fiatAmount = currency.convert(sats: totalFee) {
                    BodyMText(
                        t(
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
                        t(
                            "settings__general__speed_fee_total",
                            variables: [
                                "feeSats": String(totalFee),
                            ]
                        )
                    )
                }
            }

            Spacer()

            NumberPad { key in
                handleNumberPadInput(key)
            }

            CustomButton(
                title: t("common__continue"),
                isDisabled: !isValid
            ) {
                // Save the custom speed setting
                settings.defaultTransactionSpeed = .custom(satsPerVByte: feeRate)
                navigation.navigateBack()
            }
            .accessibilityIdentifier("Continue")
            .padding(.top, 16)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .onAppear {
            // Initialize from current setting if it's custom
            if case let .custom(currentRate) = settings.defaultTransactionSpeed {
                feeRate = currentRate
                isPresetSelected = currentRate > 0
            }
        }
    }

    private func handleNumberPadInput(_ key: String) {
        feeRate = customFeeRate(after: key, from: feeRate, replacing: isPresetSelected)
        isPresetSelected = false
    }
}
