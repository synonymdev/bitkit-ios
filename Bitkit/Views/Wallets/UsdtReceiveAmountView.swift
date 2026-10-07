import BitkitCore
import SwiftUI

struct UsdtReceiveAmountView: View {
    @Binding var amount: String
    let busy: Bool
    let error: String?
    let allowEmpty: Bool
    let onContinue: () async -> Void

    @EnvironmentObject private var currency: CurrencyViewModel
    @State private var bitcoinInput: String?
    @State private var conversionError: String?

    private var isSatsInput: Bool {
        bitcoinInput != nil && currency.displayUnit == .modern
    }

    private var canContinue: Bool {
        !busy && conversionError == nil &&
            (amount.isEmpty ? allowEmpty : (try? PaykitAmount(asset: .usdt, value: amount)) != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if let bitcoinInput {
                    VStack(alignment: .leading, spacing: 16) {
                        CaptionMText("$ " + (amount.isEmpty ? "0" : amount), textColor: .textSecondary)
                        NumberPadAmountText(value: bitcoinInput.isEmpty ? "0" : bitcoinInput, symbol: "₿")
                    }
                } else {
                    UsdtAmountHeader(amount: amount.isEmpty ? "0" : amount, network: "Arbitrum One")
                }
                Spacer(minLength: 16)
                HStack(alignment: .bottom, spacing: 16) {
                    if let message = conversionError ?? error { BodySText(message, textColor: .brandAccent) }
                    Spacer(minLength: 0)
                    NumberPadActionButton(text: bitcoinInput == nil ? "USD" : "BTC", imageName: "arrow-up-down",
                                          color: .usdtAccent, disabled: busy, action: toggleUnit)
                        .fixedSize()
                        .accessibilityIdentifier("ReceiveNumberPadUnit")
                }.padding(.bottom, 16)
            }
            .frame(minHeight: 156, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            NumberPad(type: isSatsInput ? .integer : .decimal, isDisabled: busy,
                      onDeleteLongPress: { updateInput("") })
            { key in
                updateInput(NumberPadInputHandler.handleInput(key: key, current: bitcoinInput ?? amount,
                                                              maxLength: 21, maxDecimals: isSatsInput ? 0 : (bitcoinInput == nil ? 6 : 8)))
            }
            .padding(.top, 24)
            Spacer(minLength: 24)
            CustomButton(title: t("common__continue"), isDisabled: !canContinue, isLoading: busy, action: onContinue)
                .accessibilityIdentifier("UsdtDepositCreate")
        }
    }

    private func toggleUnit() {
        conversionError = nil
        if bitcoinInput != nil { bitcoinInput = nil; return }
        guard !amount.isEmpty, amount != "0" else { bitcoinInput = ""; return }
        do {
            let bitcoin = try PaykitAmount(asset: .usdt, value: amount).converted(to: .btc, rate: currency.paykitRate, at: Date())
            // Display conversion must not round or replace the USDT amount when switching units.
            bitcoinInput = currency.displayUnit == .modern ? String(bitcoin.atomic) : bitcoin.value
        } catch {
            conversionError = t(error as? PaykitAmountError == .rateUnavailable
                ? "wallet__payment_request_rate_unavailable" : "usdt__error_amount")
        }
    }

    private func updateInput(_ value: String) {
        conversionError = nil
        guard bitcoinInput != nil else { amount = value; return }
        bitcoinInput = value
        guard !value.isEmpty else { amount = ""; return }
        do {
            let bitcoin: PaykitAmount
            if isSatsInput {
                guard let sats = UInt64(value), sats > 0 else { throw PaykitAmountError.invalidAmount }
                bitcoin = PaykitAmount(asset: .btc, atomic: sats)
            } else { bitcoin = try PaykitAmount(asset: .btc, value: value) }
            amount = try bitcoin.converted(to: .usdt, rate: currency.paykitRate, at: Date()).value
        } catch {
            conversionError = t(error as? PaykitAmountError == .rateUnavailable
                ? "wallet__payment_request_rate_unavailable" : "usdt__error_amount")
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
