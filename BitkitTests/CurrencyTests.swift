@testable import Bitkit
import XCTest

final class CurrencyTests: XCTestCase {
    // MARK: - isSuffixSymbolCurrency

    func testIsSuffixSymbolCurrency_ReturnsTrueForPLN() {
        XCTAssertTrue(isSuffixSymbolCurrency("PLN"))
    }

    func testIsSuffixSymbolCurrency_ReturnsTrueForCZK() {
        XCTAssertTrue(isSuffixSymbolCurrency("CZK"))
    }

    func testIsSuffixSymbolCurrency_ReturnsTrueForSEK() {
        XCTAssertTrue(isSuffixSymbolCurrency("SEK"))
    }

    func testIsSuffixSymbolCurrency_ReturnsTrueForCHF() {
        XCTAssertTrue(isSuffixSymbolCurrency("CHF"))
    }

    func testIsSuffixSymbolCurrency_ReturnsFalseForUSD() {
        XCTAssertFalse(isSuffixSymbolCurrency("USD"))
    }

    func testIsSuffixSymbolCurrency_ReturnsFalseForEUR() {
        XCTAssertFalse(isSuffixSymbolCurrency("EUR"))
    }

    func testIsSuffixSymbolCurrency_ReturnsFalseForGBP() {
        XCTAssertFalse(isSuffixSymbolCurrency("GBP"))
    }

    func testIsSuffixSymbolCurrency_ReturnsFalseForUnknownCurrency() {
        XCTAssertFalse(isSuffixSymbolCurrency("XYZ"))
    }

    // MARK: - ConvertedAmount.isSymbolSuffix

    func testConvertedAmount_IsSymbolSuffix_TrueForPLN() {
        let converted = ConvertedAmount(
            value: 0.35, formatted: "0.35", symbol: "zł",
            currency: "PLN", flag: "🇵🇱", sats: 100
        )
        XCTAssertTrue(converted.isSymbolSuffix)
    }

    func testConvertedAmount_IsSymbolSuffix_FalseForUSD() {
        let converted = ConvertedAmount(
            value: 10.50, formatted: "10.50", symbol: "$",
            currency: "USD", flag: "🇺🇸", sats: 1000
        )
        XCTAssertFalse(converted.isSymbolSuffix)
    }

    // MARK: - ConvertedAmount.formattedWithSymbol

    func testFormattedWithSymbol_PrefixCurrency() {
        let converted = ConvertedAmount(
            value: 10.50, formatted: "10.50", symbol: "$",
            currency: "USD", flag: "🇺🇸", sats: 1000
        )
        XCTAssertEqual(converted.formattedWithSymbol(), "$10.50")
    }

    func testFormattedWithSymbol_SuffixCurrency() {
        let converted = ConvertedAmount(
            value: 0.35, formatted: "0.35", symbol: "zł",
            currency: "PLN", flag: "🇵🇱", sats: 100
        )
        XCTAssertEqual(converted.formattedWithSymbol(), "0.35zł")
    }

    func testFormattedWithSymbol_SuffixCurrencyCZK() {
        let converted = ConvertedAmount(
            value: 250.00, formatted: "250.00", symbol: "Kč",
            currency: "CZK", flag: "🇨🇿", sats: 50000
        )
        XCTAssertEqual(converted.formattedWithSymbol(), "250.00Kč")
    }

    func testFormattedWithSymbol_PrefixCurrencyEUR() {
        let converted = ConvertedAmount(
            value: 10.00, formatted: "10.00", symbol: "€",
            currency: "EUR", flag: "🇪🇺", sats: 1000
        )
        XCTAssertEqual(converted.formattedWithSymbol(), "€10.00")
    }

    func testFormattedWithSymbol_SuffixCurrencyCHF() {
        let converted = ConvertedAmount(
            value: 50.00, formatted: "50.00", symbol: "CHF",
            currency: "CHF", flag: "🇨🇭", sats: 10000
        )
        XCTAssertEqual(converted.formattedWithSymbol(), "50.00CHF")
    }

    func testFormattedWithSymbol_PrefixCurrency_WithSpace() {
        let converted = ConvertedAmount(
            value: 10.50, formatted: "10.50", symbol: "$",
            currency: "USD", flag: "🇺🇸", sats: 1000
        )
        XCTAssertEqual(converted.formattedWithSymbol(withSpace: true), "$ 10.50")
    }

    func testFormattedWithSymbol_SuffixCurrency_WithSpace() {
        let converted = ConvertedAmount(
            value: 0.35, formatted: "0.35", symbol: "zł",
            currency: "PLN", flag: "🇵🇱", sats: 100
        )
        XCTAssertEqual(converted.formattedWithSymbol(withSpace: true), "0.35 zł")
    }

    // MARK: - primaryAmountText

    private func makeConverted(sats: UInt64 = 204) -> ConvertedAmount {
        ConvertedAmount(value: Decimal(string: "0.12")!, formatted: "0.12", symbol: "$", currency: "USD", flag: "🇺🇸", sats: sats)
    }

    func testPrimaryAmountText_FiatPrimaryShowsFiatWithSymbol() {
        let text = CurrencyViewModel.primaryAmountText(sats: 204, converted: makeConverted(), primaryDisplay: .fiat, displayUnit: .modern)
        XCTAssertEqual(text, "$0.12")
    }

    func testPrimaryAmountText_BitcoinPrimaryModernShowsSats() {
        let text = CurrencyViewModel.primaryAmountText(
            sats: 12345, converted: makeConverted(sats: 12345), primaryDisplay: .bitcoin, displayUnit: .modern
        )
        XCTAssertEqual(text, "₿ 12 345")
    }

    func testPrimaryAmountText_BitcoinPrimaryClassicShowsBtc() {
        let text = CurrencyViewModel.primaryAmountText(
            sats: 204, converted: makeConverted(), primaryDisplay: .bitcoin, displayUnit: .classic
        )
        XCTAssertEqual(text, "₿ 0.00000204")
    }

    func testPrimaryAmountText_FallsBackToBitcoinWithoutARate() {
        let text = CurrencyViewModel.primaryAmountText(sats: 204, converted: nil, primaryDisplay: .fiat, displayUnit: .classic)
        XCTAssertEqual(text, "₿ 204")
    }
}
