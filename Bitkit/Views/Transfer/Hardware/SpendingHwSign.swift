import BitkitCore
import SwiftUI

struct SpendingHwSign: View {
    let walletId: String

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var blocktank: BlocktankViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var transfer: TransferViewModel

    var body: some View {
        if transfer.uiState.feeSat > 0 {
            content()
        } else {
            Color.clear.onAppear { navigation.reset() }
        }
    }

    private let illustrationWidthRatio = 256.0 / 375.0
    private let illustrationTopRatio = (488.0 - 92.0) / (812.0 - 92.0 - 34.0)

    private func content() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .disabled(transfer.isSpendingBusy)
                .padding(.bottom, 16)

            ZStack(alignment: .top) {
                trezorIllustration

                belowNav()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("HardwareTransferSign")
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .task(id: transfer.uiState.feeSat) {
            transfer.warmUpHardwareConnection(walletId: walletId)
            await transfer.updateHwFundingFeeEstimate(walletId: walletId)
        }
        .onChange(of: transfer.hwSignedEvent) {
            navigation.navigate(.spendingHwSigned)
        }
        .onChange(of: transfer.hwTransferError) { _, error in
            guard let error else { return }
            app.toast(error)
            transfer.hwTransferError = nil
        }
        .sheet(isPresented: passphrasePromptBinding) {
            HwPassphrasePromptSheet(
                isVerifying: transfer.hwSpending.isVerifyingPassphrase,
                onSubmit: { passphrase in
                    guard let order = transfer.uiState.order else { return }
                    transfer.onHwPassphraseSubmit(order: order, walletId: walletId, passphrase: passphrase)
                },
                onCancel: { transfer.onHwPassphraseDismiss() }
            )
        }
        .onDisappear {
            let stillInFlow = navigation.path.contains {
                if case .spendingHwSign = $0 {
                    return true
                } else {
                    return false
                }
            }
            if !stillInFlow {
                transfer.cancelHwSigning()
            }
        }
    }

    private var passphrasePromptBinding: Binding<Bool> {
        Binding(
            get: { transfer.hwSpending.isPassphraseRequired },
            set: {
                if !$0 {
                    transfer.onHwPassphraseDismiss()
                }
            }
        )
    }

    private var isBusy: Bool {
        transfer.isSpendingBusy
    }

    private func belowNav() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DisplayText(
                t(
                    transfer.hwSpending.hasPendingBroadcast
                        ? "lightning__transfer_hw__signed_title"
                        : "lightning__transfer_hw__sign_title"
                ),
                accentColor: .purpleAccent
            )

            SpendingHwFeeGrid(state: transfer.uiState, miningFeeSats: transfer.hwSpending.miningFeeSats)
                .padding(.top, 16)

            HStack(spacing: 16) {
                CustomButton(
                    title: t("common__learn_more"),
                    size: .small,
                    isDisabled: isBusy || transfer.hwSpending.hasPendingBroadcast
                ) {
                    navigation.navigate(.transferLearnMore)
                }
                .accessibilityIdentifier("HardwareTransferSignLearnMore")

                if transfer.uiState.isAdvanced {
                    CustomButton(
                        title: t("lightning__spending_confirm__default"),
                        size: .small,
                        isDisabled: isBusy || transfer.hwSpending.hasPendingBroadcast
                    ) {
                        do {
                            let values = transfer.calculateTransferValues(
                                clientBalanceSat: transfer.uiState.clientBalanceSat,
                                blocktankInfo: blocktank.info
                            )
                            try await transfer.onDefaultClick(lspBalance: max(values.defaultLspBalance, values.minLspBalance)) {
                                try await blocktank.estimateFundingAmount(clientBalance: $0, lspBalance: $1)
                            }
                        } catch {
                            app.toast(error)
                        }
                    }
                    .accessibilityIdentifier("HardwareTransferSignDefault")
                } else {
                    CustomButton(
                        title: t("common__advanced"),
                        size: .small,
                        isDisabled: isBusy || transfer.hwSpending.hasPendingBroadcast
                    ) {
                        navigation.navigate(.spendingAdvanced(walletId: walletId))
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
                isDisabled: isBusy,
                isLoading: isBusy
            ) {
                await transfer.onTransferToSpendingHwConfirm(walletId: walletId) { clientBalance, lspBalance in
                    try await blocktank.createOrder(clientBalance: clientBalance, lspBalance: lspBalance)
                }
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
        .padding(.horizontal, -16)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct SpendingHwFeeGrid: View {
    let state: TransferUiState
    var miningFeeSats: UInt64 = 0

    private var lspFee: UInt64 {
        state.lspFeeSat
    }

    private var total: UInt64 {
        state.feeSat + miningFeeSats
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
                    amount: state.clientBalanceSat
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
