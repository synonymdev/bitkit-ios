import SwiftUI

// ReceiveNumberPad - Clean NumberPad component for receive flow
struct ReceiveNumberPad: View {
    @ObservedObject var viewModel: AmountInputViewModel
    @EnvironmentObject var currency: CurrencyViewModel

    var body: some View {
        NumberPad(
            type: viewModel.getNumberPadType(currency: currency),
            errorKey: viewModel.errorKey
        ) { key in
            viewModel.handleNumberPadInput(key, currency: currency)
        }
    }
}
