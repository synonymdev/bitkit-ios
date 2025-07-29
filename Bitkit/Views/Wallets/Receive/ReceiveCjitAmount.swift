import BitkitCore
import SwiftUI

struct ReceiveCjitAmount: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var blocktank: BlocktankViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var wallet: WalletViewModel

    @Binding var navigationPath: [ReceiveRoute]

    @State private var amountSats: UInt64 = 0
    @State private var overrideSats: UInt64?

    var minimumAmount: UInt64 {
        blocktank.minCjitSats ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: localizedString("wallet__receive_bitcoin"), showBackButton: true)

            VStack(alignment: .leading, spacing: 16) {
                AmountInput(primaryDisplay: $currency.primaryDisplay, overrideSats: $overrideSats, showConversion: true) { newSats in
                    Haptics.play(.buttonTap)
                    amountSats = newSats
                    overrideSats = nil
                }

                Spacer()

                HStack(alignment: .bottom) {
                    AvailableAmount(
                        label: localizedString("fee__minimum__title"),
                        amount: Int(minimumAmount)
                    )
                    .onTapGesture {
                        overrideSats = minimumAmount
                    }

                    Spacer()

                    NumberPadActionButton(
                        text: currency.primaryDisplay == .bitcoin ? "Bitcoin" : currency.selectedCurrency,
                        imageName: "transfer-brand",
                        color: Color.brandAccent
                    ) {
                        withAnimation {
                            currency.togglePrimaryDisplay()
                        }
                    }
                }
                .padding(.bottom, 12)
            }

            Divider()

            Spacer()

            CustomButton(title: localizedString("common__continue"), isDisabled: amountSats < minimumAmount) {
                // Wait until node is running if it's in starting state
                if await wallet.waitForNodeToRun() {
                    // Only proceed if node is running
                    do {
                        let entry = try await blocktank.createCjit(amountSats: amountSats, description: "Bitkit")
                        navigationPath.append(.cjitConfirm(entry: entry, receiveAmountSats: amountSats))
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
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .task {
            try? await blocktank.refreshMinCjitSats()
        }
    }
}
