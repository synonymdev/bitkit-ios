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

    /// Figma "Visual" width as a fraction of the 375-wide frame (256/375).
    private let illustrationWidthRatio = 256.0 / 375.0
    /// Figma top of the Trezor "Visual" within the content area below the nav bar:
    /// (visualTop - navHeight) / (frameHeight - navHeight - homeIndicator).
    private let illustrationTopRatio = (488.0 - 92.0) / (812.0 - 92.0 - 34.0)

    private func content(order: IBtOrder) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .padding(.bottom, 16)

            // The Trezor is a background visual behind the content (including the bottom button), so
            // it renders at its natural aspect and doesn't get squeezed by the vertical layout.
            ZStack(alignment: .top) {
                trezorIllustration

                belowNav(order: order)
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task(id: order.id) {
            transfer.warmUpHardwareConnection(deviceId: deviceId)
            await transfer.updateHwFundingFeeEstimate(order: order, deviceId: deviceId)
        }
        .onChange(of: transfer.hwSignedEvent) {
            navigation.navigate(.spendingHwSigned)
        }
        .onChange(of: transfer.hwTransferError) { _, error in
            guard let error else { return }
            app.toast(error)
            transfer.hwTransferError = nil
        }
        .onDisappear {
            // Cancel an in-flight sign only when the user truly leaves the flow (back/reset), not when
            // pushing deeper (Learn More / Advanced / Signed) which keeps this route in the path.
            let stillInFlow = navigation.path.contains {
                if case .spendingHwSign = $0 { return true } else { return false }
            }
            if !stillInFlow { transfer.cancelHwSigning() }
        }
    }

    private func belowNav(order: IBtOrder) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DisplayText(
                t(
                    transfer.hwSpending.hasPendingBroadcast
                        ? "lightning__transfer_hw__signed_title"
                        : "lightning__transfer_hw__sign_title"
                ),
                accentColor: .purpleAccent
            )

            SpendingHwFeeGrid(order: order, miningFeeSats: transfer.hwSpending.miningFeeSats)
                .padding(.top, 16)

            HStack(spacing: 16) {
                CustomButton(
                    title: t("common__learn_more"),
                    size: .small,
                    isDisabled: transfer.hwSpending.isSigning || transfer.hwSpending.hasPendingBroadcast
                ) {
                    navigation.navigate(.transferLearnMore(order: order))
                }
                .accessibilityIdentifier("HardwareTransferSignLearnMore")

                if transfer.uiState.isAdvanced {
                    CustomButton(
                        title: t("lightning__spending_confirm__default"),
                        size: .small,
                        isDisabled: transfer.hwSpending.isSigning || transfer.hwSpending.hasPendingBroadcast
                    ) {
                        transfer.onDefaultClick()
                    }
                    .accessibilityIdentifier("HardwareTransferSignDefault")
                } else {
                    CustomButton(
                        title: t("common__advanced"),
                        size: .small,
                        isDisabled: transfer.hwSpending.isSigning || transfer.hwSpending.hasPendingBroadcast
                    ) {
                        navigation.navigate(.spendingAdvanced(order: order))
                    }
                    .accessibilityIdentifier("HardwareTransferSignAdvanced")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 24)

            Spacer()

            CustomButton(
                title: t(
                    transfer.hwSpending.hasPendingBroadcast
                        ? "common__retry"
                        : "lightning__transfer_hw__open_connect"
                ),
                isDisabled: transfer.hwSpending.isSigning,
                isLoading: transfer.hwSpending.isSigning
            ) {
                transfer.onTransferToSpendingHwConfirm(order: order, deviceId: deviceId)
            }
            .accessibilityIdentifier("HardwareTransferOpenTrezorConnect")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var trezorIllustration: some View {
        GeometryReader { geo in
            let side = geo.size.width * illustrationWidthRatio
            Image("trezor-card")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: side, height: side)
                .position(x: geo.size.width / 2, y: geo.size.height * illustrationTopRatio + side / 2)
        }
        // Span the full screen width (negate the screen's horizontal content padding) so the visual
        // matches the Figma sizing, which is measured against the full frame.
        .padding(.horizontal, -16)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Blocktank order fee summary shared by the hardware Sign and Signed screens.
struct SpendingHwFeeGrid: View {
    let order: IBtOrder
    var miningFeeSats: UInt64 = 0

    private var lspFee: UInt64 {
        order.feeSat - order.clientBalanceSat
    }

    private var total: UInt64 {
        order.feeSat + miningFeeSats
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                FeeDisplayRow(
                    label: t("lightning__spending_confirm__network_fee"),
                    amount: miningFeeSats
                )
                .frame(maxWidth: .infinity)

                FeeDisplayRow(
                    label: t("lightning__spending_confirm__lsp_fee"),
                    amount: lspFee
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
                    amount: total
                )
                .frame(maxWidth: .infinity)
            }
        }
    }
}
