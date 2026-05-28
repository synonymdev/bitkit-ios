import Foundation

@Observable
final class CalculatorInputManager {
    struct SubmittedKey: Equatable {
        let id = UUID()
        let value: String
    }

    var activeInput: CalculatorMoneyType?
    var numberPadType: NumberPadType = .integer
    var decimalSeparator = "."
    var errorKey: String?
    var submittedKey: SubmittedKey?

    var isPresented: Bool {
        activeInput != nil
    }

    func activate(_ input: CalculatorMoneyType, numberPadType: NumberPadType, decimalSeparator: String) {
        activeInput = input
        self.numberPadType = numberPadType
        self.decimalSeparator = decimalSeparator
        errorKey = nil
    }

    func updateConfiguration(numberPadType: NumberPadType, decimalSeparator: String) {
        self.numberPadType = numberPadType
        self.decimalSeparator = decimalSeparator
    }

    func submit(_ key: String) {
        submittedKey = SubmittedKey(value: key)
    }

    func clear() {
        submittedKey = SubmittedKey(value: "clear")
    }

    func dismiss() {
        activeInput = nil
        errorKey = nil
        submittedKey = nil
    }
}
