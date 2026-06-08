import SwiftUI

struct BTCPayConnectionConfig {
    let setup: SamRockSetupRequest
}

struct BTCPayConnectionSheetItem: SheetItem {
    let id: SheetID = .btcpayConnection
    let size: SheetSize = .medium
    let setup: SamRockSetupRequest
}

struct BTCPayConnectionSheet: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel

    let config: BTCPayConnectionSheetItem

    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        Sheet(id: .btcpayConnection, data: config) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: t("btcpay__sheet_title"))

                HStack(alignment: .center, spacing: 16) {
                    Image("storefront")
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(.brandAccent)
                        .frame(width: 56, height: 56)
                        .padding(14)
                        .background(Color.white08)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 6) {
                        CaptionMText(t("btcpay__store_label"), textColor: .white64)

                        TitleText(config.setup.hostDisplayName)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                }
                .padding(.bottom, 24)

                BodyMText(t("btcpay__sheet_description"))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 20)

                VStack(alignment: .leading, spacing: 12) {
                    BTCPayConnectionRow(
                        iconName: "btc",
                        title: t("btcpay__onchain_label"),
                        description: t("btcpay__descriptor_label"),
                        iconColor: .brandAccent
                    )

                    if config.setup.requestsUnsupportedMethods {
                        BTCPayConnectionRow(
                            iconName: "warning",
                            title: t("btcpay__limited_support_label"),
                            description: t("btcpay__unsupported_note"),
                            iconColor: .yellowAccent
                        )
                    }
                }

                if let errorMessage {
                    BodySText(errorMessage, textColor: .redAccent)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 16)
                }

                Spacer()

                HStack(alignment: .center, spacing: 16) {
                    CustomButton(
                        title: t("common__cancel"),
                        variant: .secondary,
                        isDisabled: isConnecting
                    ) {
                        sheets.hideSheet()
                    }
                    .accessibilityIdentifier("BTCPayCancel")

                    CustomButton(
                        title: t("btcpay__button_connect"),
                        isLoading: isConnecting
                    ) {
                        await connect()
                    }
                    .accessibilityIdentifier("BTCPayConnect")
                }
                .padding(.top, 32)
            }
            .padding(.horizontal, 16)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("BTCPayConnection")
        }
    }

    private func connect() async {
        guard !isConnecting else { return }

        isConnecting = true
        errorMessage = nil

        defer {
            isConnecting = false
        }

        do {
            try await SamRockService.shared.registerBitcoinOnchain(config.setup)
            app.toast(
                type: .success,
                title: t("btcpay__success_title"),
                description: t("btcpay__success_description")
            )
            sheets.hideSheetIfActive(.btcpayConnection, reason: "BTCPay connection completed")
        } catch {
            Logger.error(error, context: "BTCPayConnectionSheet")
            let message = error.localizedDescription
            errorMessage = message
            app.toast(
                type: .error,
                title: t("btcpay__error_title"),
                description: message
            )
        }
    }
}

private struct BTCPayConnectionRow: View {
    let iconName: String
    let title: String
    let description: String
    let iconColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(iconName)
                .resizable()
                .scaledToFit()
                .foregroundColor(iconColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                BodyMSBText(title, textColor: .textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                BodySText(description, textColor: .textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white08)
        .cornerRadius(8)
    }
}
