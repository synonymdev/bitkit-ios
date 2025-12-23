import BitkitCore
import SwiftUI

struct ReceiveCjitConfirmation: View {
    @Binding var navigationPath: [ReceiveRoute]
    let entry: IcJitEntry
    let receiveAmountSats: UInt64
    let isAdditional: Bool

    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var settings: SettingsViewModel

    private func formattedNetworkFee() -> String {
        guard let converted = currency.convert(sats: entry.networkFeeSat) else {
            return String(entry.networkFeeSat)
        }
        return "\(converted.symbol)\(converted.formatted)"
    }

    private func formattedServiceFee() -> String {
        guard let converted = currency.convert(sats: entry.serviceFeeSat) else {
            return String(entry.serviceFeeSat)
        }
        return "\(converted.symbol)\(converted.formatted)"
    }

    var receiveAmount: Int {
        Int(receiveAmountSats - entry.feeSat)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__receive_bitcoin"), showBackButton: true)

            VStack(alignment: .leading, spacing: 0) {
                MoneyStack(sats: Int(receiveAmountSats), showSymbol: true)
                    .padding(.bottom, 32)

                BodyMText(
                    t(
                        isAdditional ? "wallet__receive_connect_additional" : "wallet__receive_connect_initial",
                        variables: [
                            "networkFee": formattedNetworkFee(),
                            "serviceFee": formattedServiceFee(),
                        ]
                    ),
                    accentColor: .white,
                    accentFont: Fonts.bold
                )
                .padding(.bottom, 32)

                VStack(alignment: .leading, spacing: 4) {
                    CaptionMText(t("wallet__receive_will"))
                    MoneyText(sats: receiveAmount, size: .title, symbol: true)
                }
            }

            Spacer()

            HStack(alignment: .center, spacing: 0) {
                BodyMText(tTodo("Enable background setup"), textColor: .textPrimary)

                Spacer()

                Toggle("", isOn: $settings.enableNotifications)
                    .toggleStyle(SwitchToggleStyle(tint: .brandAccent))
                    .labelsHidden()
            }
            .frame(height: 50)
            .padding(.bottom, 8)

            Divider()
                .padding(.bottom, 22)

            HStack(spacing: 16) {
                CustomButton(title: t("common__learn_more"), variant: .secondary) {
                    navigationPath.append(.cjitLearnMore(entry: entry, receiveAmountSats: receiveAmountSats, isAdditional: isAdditional))
                }

                CustomButton(title: t("common__continue")) {
                    navigationPath.append(.qr(cjitInvoice: entry.invoice.request, tab: .spending))
                }
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
