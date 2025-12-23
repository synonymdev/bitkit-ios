import BitkitCore
import SwiftUI

struct ReceiveCjitAmount: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var blocktank: BlocktankViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    @Binding var navigationPath: [ReceiveRoute]

    @StateObject private var amountViewModel = AmountInputViewModel()

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
                NumberPadTextField(viewModel: amountViewModel)
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
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .task {
            try? await blocktank.refreshMinCjitSats()
        }
    }

    private func onContinue() async {
        // Wait until node is running if it's in starting state
        if await wallet.waitForNodeToRun() {
            // Only proceed if node is running
            do {
                let entry = try await blocktank.createCjit(amountSats: amountSats, description: "Bitkit")
                navigationPath.append(.cjitConfirm(entry: entry, receiveAmountSats: amountSats, isAdditional: false))
            } catch {
                app.toast(error)
                Logger.error(error)
            }
        } else {
            // Show error if node is not running or timed out
            app.toast(type: .warning, title: "Lightning not ready", description: "Lightning node must be running to create an invoice")
        }
    }
}
