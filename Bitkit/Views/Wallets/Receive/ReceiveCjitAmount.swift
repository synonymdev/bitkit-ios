import BitkitCore
import SwiftUI

struct ReceiveCjitAmount: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var blocktank: BlocktankViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    @Binding var navigationPath: [ReceiveRoute]

    @State private var amountViewModel = AmountInputViewModel()
    @State private var maxCjitAmount: UInt64?

    var minimumAmount: UInt64 {
        blocktank.minCjitSats ?? 0
    }

    var amountSats: UInt64 {
        amountViewModel.amountSats
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("wallet__receive_bitcoin"), showBackButton: true)

            VStack(alignment: .leading, spacing: 0) {
                NumberPadTextField(viewModel: amountViewModel, testIdentifier: "ReceiveCjitAmountNumberField")
                    .onTapGesture {
                        amountViewModel.togglePrimaryDisplay(currency: currency)
                    }

                Spacer()

                HStack(alignment: .bottom) {
                    AvailableAmount(
                        label: t("fee__minimum__title"),
                        amount: Int(minimumAmount)
                    )
                    .onTapGesture {
                        amountViewModel.updateFromSats(minimumAmount, currency: currency)
                    }

                    Spacer()

                    NumberPadActionButton(
                        text: currency.primaryDisplay == .bitcoin ? "Bitcoin" : currency.selectedCurrency,
                        imageName: "transfer",
                        color: .brandAccent
                    ) {
                        withAnimation {
                            amountViewModel.togglePrimaryDisplay(currency: currency)
                        }
                    }
                }
                .padding(.bottom, 8)

                Divider()

                NumberPad(
                    type: amountViewModel.getNumberPadType(currency: currency),
                    errorKey: amountViewModel.errorKey
                ) { key in
                    amountViewModel.handleNumberPadInput(key, currency: currency)
                }
            }

            CustomButton(title: t("common__continue"), isDisabled: amountSats < minimumAmount) {
                Task {
                    await onContinue()
                }
            }
            .accessibilityIdentifier("ReceiveCjitAmountContinue")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ReceiveCjitAmount")
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .task {
            try? await blocktank.refreshMinCjitSats()
            await refreshMaxCjitAmount()
            updateInputCap()
        }
        .onChange(of: blocktank.info?.options.maxChannelSizeSat) {
            Task {
                await refreshMaxCjitAmount()
            }
        }
        .onChange(of: maxCjitAmount) {
            updateInputCap()
        }
        .onChange(of: amountViewModel.maxExceededCount) {
            showMaxExceededToast()
        }
    }

    private func onContinue() async {
        if maxCjitAmount == nil {
            await refreshMaxCjitAmount()
            updateInputCap()
        }

        guard isWithinMaxCjitAmount else {
            showMaxExceededToast()
            return
        }

        // Wait until node is running if it's in starting state
        if await wallet.waitForNodeToRun() {
            // Only proceed if node is running
            do {
                let entry = try await blocktank.createCjit(amountSats: amountSats, description: "Bitkit")
                navigationPath.append(.cjitConfirm(entry: entry, receiveAmountSats: amountSats, isAdditional: false))
            } catch {
                if isMaxCjitAmountError(error) {
                    if maxCjitAmount == nil {
                        await refreshMaxCjitAmount()
                        updateInputCap()
                    }
                    showMaxExceededToast()
                    Logger.error(error)
                    return
                }

                app.toast(error)
                Logger.error(error)
            }
        } else {
            // Show error if node is not running or timed out
            app.toast(type: .warning, title: "Lightning not ready", description: "Lightning node must be running to create an invoice")
        }
    }

    private var isWithinMaxCjitAmount: Bool {
        guard let maxCjitAmount, maxCjitAmount > 0 else {
            return true
        }

        return amountSats <= maxCjitAmount
    }

    private func updateInputCap() {
        amountViewModel.maxAmountOverride = (maxCjitAmount ?? 0) > 0 ? maxCjitAmount : nil
    }

    private func refreshMaxCjitAmount() async {
        do {
            maxCjitAmount = try await blocktank.maxCjitAmountSats()
        } catch {
            Logger.error("Failed to calculate max CJIT amount: \(error)")
            maxCjitAmount = nil
        }
    }

    private func showMaxExceededToast() {
        app.toast(
            type: .warning,
            title: t("wallet__receive_cjit_error_max__title"),
            description: t(
                "wallet__receive_cjit_error_max__description",
                variables: ["amount": CurrencyFormatter.formatSats(maxCjitAmount ?? 0)]
            ),
            accessibilityIdentifier: "ReceiveCjitAmountExceededToast"
        )
    }

    private func isMaxCjitAmountError(_ error: Error) -> Bool {
        let description = String(describing: error)
        return description.contains("Channel size is too big")
            || description.contains("channelSizeExceedsMaximum")
            || description.contains("maxChannelSizeSat")
            || description.contains("channelSizeSat")
    }
}
