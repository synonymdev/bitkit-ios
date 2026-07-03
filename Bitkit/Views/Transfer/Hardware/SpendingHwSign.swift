import BitkitCore
import SwiftUI

/// "Sign with your device" — shows the Blocktank order fees and asks the user to sign the funding
/// transaction on the Trezor. Reuses the existing Learn More / Advanced controls; on-device signing
/// replaces the local swipe-to-pay. Advances to the Signed screen on success.
struct SpendingHwSign: View {
    let deviceId: String

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var transfer: TransferViewModel

    var body: some View {
        Group {
            if let order = transfer.uiState.order {
                content(order: transfer.displayOrder(for: order))
            } else {
                // No active order (e.g. after process death) — bail back to the wallet.
                Color.clear.onAppear { navigation.reset() }
            }
        }
    }

    private func content(order: IBtOrder) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .padding(.bottom, 16)

            DisplayText(t("lightning__transfer_hw__sign_title"), accentColor: .purpleAccent)

            SpendingHwFeeGrid(order: order)
                .padding(.top, 16)

            HStack(spacing: 16) {
                CustomButton(title: t("common__learn_more"), size: .small) {
                    navigation.navigate(.transferLearnMore(order: order))
                }
                .accessibilityIdentifier("HardwareTransferSignLearnMore")

                if transfer.uiState.isAdvanced {
                    CustomButton(title: t("lightning__spending_confirm__default"), size: .small) {
                        transfer.onDefaultClick()
                    }
                    .accessibilityIdentifier("HardwareTransferSignDefault")
                } else {
                    CustomButton(title: t("common__advanced"), size: .small) {
                        navigation.navigate(.spendingAdvanced(order: order))
                    }
                    .accessibilityIdentifier("HardwareTransferSignAdvanced")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 24)

            trezorIllustration

            Spacer()

            CustomButton(
                title: t("lightning__transfer_hw__open_connect"),
                isDisabled: transfer.hwSpending.isSigning,
                isLoading: transfer.hwSpending.isSigning
            ) {
                transfer.onTransferToSpendingHwConfirm(order: order, deviceId: deviceId)
            }
            .accessibilityIdentifier("HardwareTransferOpenTrezorConnect")
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .onChange(of: transfer.hwSignedEvent) {
            navigation.navigate(.spendingHwSigned)
        }
        .onChange(of: transfer.hwTransferError) { _, error in
            guard let error else { return }
            showToast(for: error)
            transfer.hwTransferError = nil
        }
    }

    private var trezorIllustration: some View {
        Image("trezor-device")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .padding(.top, 24)
            .accessibilityHidden(true)
    }

    private func showToast(for error: HwTransferError) {
        switch error {
        case .reconnect:
            app.toast(
                type: .error,
                title: t("lightning__transfer_hw__reconnect_error_title"),
                description: t("lightning__transfer_hw__reconnect_error_description")
            )
        case .signingTimeout:
            app.toast(
                type: .error,
                title: t("common__error"),
                description: t("wallet__toast_payment_failed_timeout")
            )
        case let .funding(message):
            app.toast(type: .error, title: t("common__error"), description: message ?? t("common__error_body"))
        case let .generic(message):
            app.toast(type: .error, title: t("common__error"), description: message ?? t("common__error_body"))
        }
    }
}

/// Blocktank order fee summary shared by the hardware Sign and Signed screens.
struct SpendingHwFeeGrid: View {
    let order: IBtOrder

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                FeeDisplayRow(
                    label: t("lightning__spending_confirm__network_fee"),
                    amount: order.networkFeeSat
                )
                .frame(maxWidth: .infinity)

                FeeDisplayRow(
                    label: t("lightning__spending_confirm__lsp_fee"),
                    amount: order.serviceFeeSat
                )
                .frame(maxWidth: .infinity)
            }

            HStack {
                FeeDisplayRow(
                    label: t("lightning__spending_confirm__amount"),
                    amount: order.clientBalanceSat
                )
                .frame(maxWidth: .infinity)

                FeeDisplayRow(
                    label: t("lightning__spending_confirm__total"),
                    amount: order.feeSat
                )
                .frame(maxWidth: .infinity)
            }
        }
    }
}
