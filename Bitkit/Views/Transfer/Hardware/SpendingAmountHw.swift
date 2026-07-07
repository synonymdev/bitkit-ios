import BitkitCore
import LDKNode
import SwiftUI

/// Amount entry for a transfer to spending funded from a paired hardware wallet. Mirrors
/// `SpendingAmount`, but the available/MAX/quarter limits come from the device's native-segwit
/// balance via `TransferViewModel.updateHwLimits`, and Continue advances to the on-device Sign step.
struct SpendingAmountHw: View {
    let deviceId: String

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var blocktank: BlocktankViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var transfer: TransferViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var amountViewModel = AmountInputViewModel()
    @State private var isLoading = false

    private var amountSats: UInt64 {
        amountViewModel.amountSats
    }

    private var maxAllowed: UInt64 {
        transfer.hwSpending.maxAllowedToSend
    }

    /// Inputs the limit calculation depends on. Keying the `.task` on this reruns `updateHwLimits`
    /// when Blocktank info arrives after the screen opens (the LSP caps are otherwise nil → 0 limits).
    private struct HwLimitInputs: Equatable {
        let deviceId: String
        let maxChannelSizeSat: UInt64?
        let maxClientBalanceSat: UInt64?
    }

    private var hwLimitInputs: HwLimitInputs {
        HwLimitInputs(
            deviceId: deviceId,
            maxChannelSizeSat: blocktank.info?.options.maxChannelSizeSat,
            maxClientBalanceSat: blocktank.info?.options.maxClientBalanceSat
        )
    }

    private var isValidAmount: Bool {
        !transfer.hwSpending.isLoading && maxAllowed > 0 && amountSats <= maxAllowed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("lightning__transfer__nav_title"))
                .padding(.bottom, 16)

            DisplayText(t("lightning__spending_amount__title"), accentColor: .purpleAccent)
                .fixedSize(horizontal: false, vertical: true)

            NumberPadTextField(viewModel: amountViewModel, showConversion: false)
                .onTapGesture {
                    amountViewModel.togglePrimaryDisplay(currency: currency)
                }
                .padding(.top, 32)

            Spacer()

            HStack(alignment: .bottom) {
                if transfer.hwSpending.isLoading {
                    HStack(spacing: 4) {
                        CaptionMText(t("wallet__send_available"))
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                } else {
                    AvailableAmount(
                        label: t("wallet__send_available"),
                        amount: Int(transfer.hwSpending.balanceAfterFee),
                        testIdentifier: "HardwareTransferAmountAvailable"
                    )
                }

                Spacer()

                actionButtons
            }
            .padding(.bottom, 12)

            Divider()

            NumberPad(
                type: amountViewModel.getNumberPadType(currency: currency),
                errorKey: amountViewModel.errorKey,
                isDisabled: transfer.hwSpending.isLoading
            ) { key in
                amountViewModel.handleNumberPadInput(key, currency: currency)
            }

            CustomButton(
                title: t("common__continue"),
                isDisabled: !isValidAmount,
                isLoading: isLoading
            ) {
                await onContinue()
            }
            .accessibilityIdentifier("HardwareTransferAmountContinue")
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .bottomSafeAreaPadding()
        .offlineOverlay(title: t("lightning__transfer__nav_title"))
        .task(id: hwLimitInputs) {
            await transfer.updateHwLimits(
                deviceId: deviceId,
                blocktankInfo: blocktank.info,
                estimateOrderFee: { clientBalance, lspBalance in
                    let estimate = try await blocktank.estimateOrderFee(clientBalance: clientBalance, lspBalance: lspBalance)
                    return (estimate.networkFeeSat, estimate.serviceFeeSat)
                }
            )
        }
        .onChange(of: maxAllowed) { updateInputCap() }
        .onChange(of: amountViewModel.maxExceededCount) { onMaxExceeded() }
        .onChange(of: transfer.hwTransferError) { _, error in
            guard let error else { return }
            app.toast(error)
            transfer.hwTransferError = nil
        }
    }

    private func updateInputCap() {
        amountViewModel.maxAmountOverride = maxAllowed > 0 ? maxAllowed : nil
    }

    private func onMaxExceeded() {
        amountViewModel.updateFromSats(maxAllowed, currency: currency)
        app.toast(
            type: .warning,
            title: t("lightning__spending_amount__error_max__title"),
            description: t(
                "lightning__spending_amount__error_max__description",
                variables: ["amount": CurrencyFormatter.formatSats(maxAllowed)]
            ),
            visibilityTime: Toast.visibilityTimeShort
        )
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            NumberPadActionButton(
                text: currency.primaryDisplay == .bitcoin ? "Bitcoin" : currency.selectedCurrency,
                imageName: "arrow-up-down"
            ) {
                withAnimation {
                    amountViewModel.togglePrimaryDisplay(currency: currency)
                }
            }

            NumberPadActionButton(text: t("lightning__spending_amount__quarter")) {
                amountViewModel.updateFromSats(transfer.hwSpending.quarterAmount, currency: currency)
            }
            .accessibilityIdentifier("HardwareTransferAmountQuarter")

            NumberPadActionButton(text: t("common__max")) {
                amountViewModel.updateFromSats(maxAllowed, currency: currency)
            }
            .accessibilityIdentifier("HardwareTransferAmountMax")
        }
    }

    private func onContinue() async {
        isLoading = true
        defer { isLoading = false }

        // Wait for the node to be running if it's not already (needed to open the channel later).
        if wallet.nodeLifecycleState != .running {
            let isReady = await wallet.waitForNodeToRun(timeoutSeconds: 30.0)
            guard isReady else {
                app.toast(
                    type: .error,
                    title: "Lightning node not ready",
                    description: "Please wait for the Lightning node to start and try again."
                )
                return
            }
        }

        do {
            let values = transfer.calculateTransferValues(clientBalanceSat: amountSats, blocktankInfo: blocktank.info)
            let lspBalance = max(values.defaultLspBalance, values.minLspBalance)
            let order = try await blocktank.createOrder(clientBalance: amountSats, lspBalance: lspBalance)

            transfer.onOrderCreated(order: order)
            navigation.navigate(.spendingHwSign(deviceId: deviceId))
        } catch {
            let appError = AppError(error: error)
            app.toast(type: .error, title: appError.message, description: appError.debugMessage)
        }
    }
}
