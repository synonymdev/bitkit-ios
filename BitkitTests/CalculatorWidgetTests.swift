@testable import Bitkit
import XCTest

final class CalculatorWidgetTests: XCTestCase {
    func testModernBitcoinFormattingUsesSpaceGrouping() {
        XCTAssertEqual(
            CalculatorWidgetFormatter.formatBitcoinValue("1800000000", displayUnit: .modern),
            "1 800 000 000"
        )
    }

    func testFiatFormattingUsesCommaGroupingAndPlaceholderZero() {
        XCTAssertEqual(CalculatorWidgetFormatter.formatFiatValue("82209.8"), "82,209.8")
        XCTAssertEqual(CalculatorWidgetFormatter.formatFiatPlaceholder("82209.8"), "0")
    }

    func testNumberPadDeleteOperatesOnRawValue() {
        let next = CalculatorWidgetFormatter.applyNumberPadInput(
            rawValue: "1000",
            key: "delete",
            maxDecimalPlaces: CalculatorWidgetFormatter.fiatDecimalPlaces
        )

        XCTAssertEqual(next, "100")
        XCTAssertEqual(CalculatorWidgetFormatter.formatFiatValue(next), "100")
    }

    func testNumberPadCapsFiatDecimals() {
        let value = CalculatorWidgetFormatter.applyNumberPadInput(
            rawValue: "1.50",
            key: "0",
            maxDecimalPlaces: CalculatorWidgetFormatter.fiatDecimalPlaces
        )

        XCTAssertEqual(value, "1.50")
    }

    func testLocalizedCommaDecimalInputNormalizesToCalculatorDecimal() {
        let locale = Locale(identifier: "fr_BE")
        let value = CalculatorWidgetFormatter.applyNumberPadInput(
            rawValue: "1,",
            key: "5",
            maxDecimalPlaces: CalculatorWidgetFormatter.fiatDecimalPlaces,
            locale: locale
        )

        XCTAssertEqual(value, "1.5")
    }

    func testCurrencySymbolFallsBackToFirstCharacterForLongSymbols() {
        XCTAssertEqual(CalculatorWidgetFormatter.displaySymbol("CHF"), "C")
        XCTAssertEqual(CalculatorWidgetFormatter.displaySymbol("$"), "$")
    }

    func testClassicBitcoinConvertsToSats() {
        XCTAssertEqual(
            CalculatorWidgetFormatter.bitcoinValueToSats("0.00010000", displayUnit: .classic),
            10000
        )
    }
}
