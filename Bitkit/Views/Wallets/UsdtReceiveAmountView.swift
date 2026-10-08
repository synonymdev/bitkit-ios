import BitkitCore
import SwiftUI

struct UsdtReceiveAmountView: View {
    @Binding var amount: String
    let busy: Bool
    let error: String?
    let allowEmpty: Bool
    let onContinue: () async -> Void

    private var canContinue: Bool {
        !busy && (amount.isEmpty ? allowEmpty : (try? PaykitAmount(asset: .usdt, value: amount)) != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                UsdtAmountHeader(amount: amount.isEmpty ? "0" : amount)
                Spacer(minLength: 16)
                if let error {
                    BodySText(error, textColor: .brandAccent)
                        .padding(.bottom, 16)
                }
            }
            .frame(minHeight: 156, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            NumberPad(type: .decimal, isDisabled: busy, onDeleteLongPress: { amount = "" }) { key in
                amount = NumberPadInputHandler.handleInput(key: key, current: amount, maxLength: 21, maxDecimals: 6)
            }
            .padding(.top, 24)
            Spacer(minLength: 24)
            CustomButton(title: t("common__continue"), isDisabled: !canContinue, isLoading: busy, action: onContinue)
                .accessibilityIdentifier("UsdtDepositCreate")
        }
    }
}

@MainActor
func usdtDepositAmountMessage(_ error: Error, amount: String) -> String {
    if let error = error as? UsdtError, case let .DepositAmountOutOfRange(min, max) = error,
       let value = Decimal(string: amount)
    {
        if let min, let cents = Decimal(string: min), value < cents / 100 {
            return t("usdt__deposit_minimum", variables: ["amount": min.usdCents])
        }
        if let max, let cents = Decimal(string: max), value > cents / 100 {
            return t("usdt__deposit_maximum", variables: ["amount": max.usdCents])
        }
    }
    return UsdtWalletManager.message(for: error)
}
