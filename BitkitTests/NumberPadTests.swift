@testable import Bitkit
import XCTest

@MainActor
final class NumberPadTests: XCTestCase {
    func testFiatDecimalInput() {
        let viewModel = AmountInputViewModel()
        let currency = mockCurrency(primaryDisplay: .fiat)

        // Test building up decimal input
        viewModel.handleNumberPadInput("1", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1")

        viewModel.handleNumberPadInput(".", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1.")

        viewModel.handleNumberPadInput("0", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1.0")
    }

    // MARK: - Modern Bitcoin Tests

    func testModernBitcoinInput() {
        let viewModel = AmountInputViewModel()
        let currency = mockCurrency(primaryDisplay: .bitcoin, displayUnit: .modern)

        viewModel.handleNumberPadInput("1", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1")

        viewModel.handleNumberPadInput("0", currency: currency)
        XCTAssertEqual(viewModel.displayText, "10")

        viewModel.handleNumberPadInput("0", currency: currency)
        XCTAssertEqual(viewModel.displayText, "100")

        viewModel.handleNumberPadInput("0", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1 000")
    }

    func testModernBitcoinMaxAmount() {
        let viewModel = AmountInputViewModel()
        let currency = mockCurrency(primaryDisplay: .bitcoin, displayUnit: .modern)

        // Test max amount
        for digit in "999999999" {
            viewModel.handleNumberPadInput(String(digit), currency: currency)
        }
        XCTAssertEqual(viewModel.amountSats, 999_999_999)

        // Test exceeding max amount
        viewModel.handleNumberPadInput("0", currency: currency)
        XCTAssertEqual(viewModel.amountSats, 999_999_999) // Should not change
        XCTAssertNotNil(viewModel.errorKey)
    }

    // MARK: - Classic Bitcoin Tests

    func testClassicBitcoinDecimalInput() {
        let viewModel = AmountInputViewModel()
        let currency = mockCurrency(primaryDisplay: .bitcoin, displayUnit: .classic)

        viewModel.handleNumberPadInput("1", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1")

        viewModel.handleNumberPadInput(".", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1.")

        viewModel.handleNumberPadInput("0", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1.0")

        viewModel.handleNumberPadInput("0", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1.00")
    }

    func testClassicBitcoinMaxDecimals() {
        let viewModel = AmountInputViewModel()
        let currency = mockCurrency(primaryDisplay: .bitcoin, displayUnit: .classic)

        // Build up to max decimals
        viewModel.handleNumberPadInput("1", currency: currency)
        viewModel.handleNumberPadInput(".", currency: currency)

        for _ in 0 ..< 8 {
            viewModel.handleNumberPadInput("0", currency: currency)
        }
        XCTAssertEqual(viewModel.displayText, "1.00000000")

        // Try to add more decimals - should be blocked
        viewModel.handleNumberPadInput("0", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1.00000000") // Should not change
    }

    func testClassicBitcoinMaxAmount() {
        let viewModel = AmountInputViewModel()
        let currency = mockCurrency(primaryDisplay: .bitcoin, displayUnit: .classic)

        // "10" in classic Bitcoin exceeds max amount
        viewModel.handleNumberPadInput("1", currency: currency)
        viewModel.handleNumberPadInput("0", currency: currency)

        XCTAssertEqual(viewModel.amountSats, 100_000_000)
        XCTAssertNotNil(viewModel.errorKey)
    }

    // MARK: - Fiat Tests

    func testFiatGroupingSeparators() {
        let viewModel = AmountInputViewModel()
        let currency = mockCurrency(primaryDisplay: .fiat)

        viewModel.handleNumberPadInput("1", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1")

        viewModel.handleNumberPadInput("0", currency: currency)
        XCTAssertEqual(viewModel.displayText, "10")

        viewModel.handleNumberPadInput("0", currency: currency)
        XCTAssertEqual(viewModel.displayText, "100")

        viewModel.handleNumberPadInput("0", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1,000")
    }

    func testFiatMaxDecimals() {
        let viewModel = AmountInputViewModel()
        let currency = mockCurrency(primaryDisplay: .fiat)

        viewModel.handleNumberPadInput("1", currency: currency)
        viewModel.handleNumberPadInput(".", currency: currency)
        viewModel.handleNumberPadInput("5", currency: currency)
        viewModel.handleNumberPadInput("0", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1.50")

        // Try to add more decimals - should be blocked
        viewModel.handleNumberPadInput("0", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1.50") // Should not change
    }

    // MARK: - Delete Tests

    func testDeleteFromFormattedText() {
        let viewModel = AmountInputViewModel()
        let currency = mockCurrency(primaryDisplay: .fiat)

        // Build up to "1,000.00"
        viewModel.handleNumberPadInput("1", currency: currency)
        viewModel.handleNumberPadInput("0", currency: currency)
        viewModel.handleNumberPadInput("0", currency: currency)
        viewModel.handleNumberPadInput("0", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1,000")

        viewModel.handleNumberPadInput(".", currency: currency)
        viewModel.handleNumberPadInput("0", currency: currency)
        viewModel.handleNumberPadInput("0", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1,000.00")

        // Delete character by character
        viewModel.handleNumberPadInput("delete", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1,000.0")

        viewModel.handleNumberPadInput("delete", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1,000.")

        viewModel.handleNumberPadInput("delete", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1,000")
    }

    func testDeleteSpecialCases() {
        let viewModel = AmountInputViewModel()
        let currency = mockCurrency(primaryDisplay: .fiat)

        // Test "0." + delete
        viewModel.handleNumberPadInput("0", currency: currency)
        viewModel.handleNumberPadInput(".", currency: currency)
        XCTAssertEqual(viewModel.displayText, "0.")

        viewModel.handleNumberPadInput("delete", currency: currency)
        XCTAssertEqual(viewModel.displayText, "")
        XCTAssertEqual(viewModel.amountSats, 0)
    }

    // MARK: - Leading Zero Tests

    func testLeadingZeroBehavior() {
        let viewModel = AmountInputViewModel()
        let currency = mockCurrency(primaryDisplay: .fiat)

        // "0" + digit should replace "0"
        viewModel.handleNumberPadInput("0", currency: currency)
        XCTAssertEqual(viewModel.displayText, "0")

        viewModel.handleNumberPadInput("1", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1")

        // Reset and test "0" + "." should become "0."
        viewModel.handleNumberPadInput("delete", currency: currency)
        viewModel.handleNumberPadInput("0", currency: currency)
        viewModel.handleNumberPadInput(".", currency: currency)
        XCTAssertEqual(viewModel.displayText, "0.")
    }

    func testMultipleLeadingZeros() {
        let viewModel = AmountInputViewModel()
        let currency = mockCurrency(primaryDisplay: .fiat)

        // Multiple zeros should be ignored
        viewModel.handleNumberPadInput("0", currency: currency)
        viewModel.handleNumberPadInput("0", currency: currency)
        viewModel.handleNumberPadInput("0", currency: currency)
        viewModel.handleNumberPadInput("1", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1")
    }

    // MARK: - Decimal Point Tests

    func testMultipleDecimalPoints() {
        let viewModel = AmountInputViewModel()
        let currency = mockCurrency(primaryDisplay: .fiat)

        viewModel.handleNumberPadInput("1", currency: currency)
        viewModel.handleNumberPadInput(".", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1.")

        // Second decimal point should be ignored
        viewModel.handleNumberPadInput(".", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1.")
    }

    func testEmptyInputDecimalPoint() {
        let viewModel = AmountInputViewModel()
        let currency = mockCurrency(primaryDisplay: .fiat)

        // Empty input + "." should become "0."
        viewModel.handleNumberPadInput(".", currency: currency)
        XCTAssertEqual(viewModel.displayText, "0.")
    }

    // MARK: - Currency Toggle Tests

    func testCurrencyTogglePreservesAmount() {
        let viewModel = AmountInputViewModel()
        let currency = mockCurrency(primaryDisplay: .bitcoin, displayUnit: .modern)

        // Set amount in Bitcoin
        viewModel.handleNumberPadInput("1", currency: currency)
        viewModel.handleNumberPadInput("0", currency: currency)
        viewModel.handleNumberPadInput("0", currency: currency)
        let bitcoinAmount = viewModel.amountSats
        XCTAssertEqual(bitcoinAmount, 100)

        // Toggle to Fiat
        viewModel.togglePrimaryDisplay(currency: currency)
        XCTAssertEqual(currency.primaryDisplay, .fiat)
        XCTAssertEqual(viewModel.amountSats, bitcoinAmount) // Amount should be preserved

        // Toggle back to Bitcoin
        viewModel.togglePrimaryDisplay(currency: currency)
        XCTAssertEqual(currency.primaryDisplay, .bitcoin)
        XCTAssertEqual(viewModel.amountSats, bitcoinAmount) // Amount should still be preserved
    }

    func testCurrencyToggleWithPartialInput() {
        let viewModel = AmountInputViewModel()
        let currency = mockCurrency(primaryDisplay: .bitcoin, displayUnit: .classic)

        // Type partial decimal input
        viewModel.handleNumberPadInput("1", currency: currency)
        viewModel.handleNumberPadInput(".", currency: currency)
        viewModel.handleNumberPadInput("5", currency: currency)
        XCTAssertEqual(viewModel.displayText, "1.5")

        // Toggle to Fiat - should convert the partial input
        viewModel.togglePrimaryDisplay(currency: currency)
        XCTAssertEqual(currency.primaryDisplay, .fiat)
        XCTAssertEqual(viewModel.amountSats, 150_000_000) // 1.5 BTC in sats
    }

    // MARK: - Placeholder Tests

    func testModernBitcoinPlaceholder() {
        let viewModel = AmountInputViewModel()
        let currency = mockCurrency(primaryDisplay: .bitcoin, displayUnit: .modern)

        // Empty input should show 0 placeholder for modern Bitcoin
        XCTAssertEqual(viewModel.getPlaceholder(currency: currency), "0")

        // Typing should not show placeholder
        viewModel.handleNumberPadInput("1", currency: currency)
        XCTAssertEqual(viewModel.getPlaceholder(currency: currency), "")
    }

    func testClassicBitcoinPlaceholder() {
        let viewModel = AmountInputViewModel()
        let currency = mockCurrency(primaryDisplay: .bitcoin, displayUnit: .classic)

        // Empty input should show full decimal placeholder
        XCTAssertEqual(viewModel.getPlaceholder(currency: currency), "0.00000000")

        // Typing "1" should show remaining decimals
        viewModel.handleNumberPadInput("1", currency: currency)
        XCTAssertEqual(viewModel.getPlaceholder(currency: currency), ".00000000")

        // Typing "1." should show remaining decimals
        viewModel.handleNumberPadInput(".", currency: currency)
        XCTAssertEqual(viewModel.getPlaceholder(currency: currency), "00000000")

        // Typing "1.5" should show remaining decimals
        viewModel.handleNumberPadInput("5", currency: currency)
        XCTAssertEqual(viewModel.getPlaceholder(currency: currency), "0000000")
    }

    func testFiatPlaceholder() {
        let viewModel = AmountInputViewModel()
        let currency = mockCurrency(primaryDisplay: .fiat)

        // Empty input should show decimal placeholder
        XCTAssertEqual(viewModel.getPlaceholder(currency: currency), "0.00")

        // Typing "1" should show decimal placeholder
        viewModel.handleNumberPadInput("1", currency: currency)
        XCTAssertEqual(viewModel.getPlaceholder(currency: currency), ".00")

        // Typing "1." should show remaining decimals
        viewModel.handleNumberPadInput(".", currency: currency)
        XCTAssertEqual(viewModel.getPlaceholder(currency: currency), "00")

        // Typing "1.5" should show remaining decimal
        viewModel.handleNumberPadInput("5", currency: currency)
        XCTAssertEqual(viewModel.getPlaceholder(currency: currency), "0")
    }

    func testPlaceholderWithLeadingZero() {
        let viewModel = AmountInputViewModel()
        let currency = mockCurrency(primaryDisplay: .fiat)

        // "0" should show decimal placeholder
        viewModel.handleNumberPadInput("0", currency: currency)
        XCTAssertEqual(viewModel.getPlaceholder(currency: currency), ".00")

        // "0." should show remaining decimals
        viewModel.handleNumberPadInput(".", currency: currency)
        XCTAssertEqual(viewModel.getPlaceholder(currency: currency), "00")
    }

    func testPlaceholderAfterDelete() {
        let viewModel = AmountInputViewModel()
        let currency = mockCurrency(primaryDisplay: .fiat)

        // Build up to "1.50"
        viewModel.handleNumberPadInput("1", currency: currency)
        viewModel.handleNumberPadInput(".", currency: currency)
        viewModel.handleNumberPadInput("5", currency: currency)
        viewModel.handleNumberPadInput("0", currency: currency)
        XCTAssertEqual(viewModel.getPlaceholder(currency: currency), "")

        // Delete to "1.5" should show remaining decimal
        viewModel.handleNumberPadInput("delete", currency: currency)
        XCTAssertEqual(viewModel.getPlaceholder(currency: currency), "0")

        // Delete to "1." should show remaining decimals
        viewModel.handleNumberPadInput("delete", currency: currency)
        XCTAssertEqual(viewModel.getPlaceholder(currency: currency), "00")

        // Delete to "1" should show decimal placeholder
        viewModel.handleNumberPadInput("delete", currency: currency)
        XCTAssertEqual(viewModel.getPlaceholder(currency: currency), ".00")
    }

    // func testPlaceholderAfterCurrencyToggle() {
    //     let viewModel = AmountInputViewModel()
    //     let currency = mockCurrency(primaryDisplay: .bitcoin, displayUnit: .classic)

    //     // Type partial input in classic Bitcoin
    //     viewModel.handleNumberPadInput("1", currency: currency)
    //     viewModel.handleNumberPadInput(".", currency: currency)
    //     viewModel.handleNumberPadInput("5", currency: currency)
    //     XCTAssertEqual(viewModel.getPlaceholder(currency: currency), "0000000")

    //     // Toggle to fiat should show not show placeholder
    //     viewModel.togglePrimaryDisplay(currency: currency)
    //     XCTAssertEqual(viewModel.getPlaceholder(currency: currency), "")

    //     // Toggle back to classic Bitcoin should show appropriate placeholder
    //     viewModel.togglePrimaryDisplay(currency: currency)
    //     XCTAssertEqual(viewModel.getPlaceholder(currency: currency), "0000000")
    // }

    // MARK: - Helper Methods

    private func mockCurrency(primaryDisplay: PrimaryDisplay, displayUnit: BitcoinDisplayUnit = .modern) -> CurrencyViewModel {
        let currency = CurrencyViewModel()
        currency.primaryDisplay = primaryDisplay
        currency.selectedCurrency = "USD"
        currency.displayUnit = displayUnit
        return currency
    }
}
