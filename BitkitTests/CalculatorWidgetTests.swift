@testable import Bitkit
import XCTest

final class CalculatorWidgetTests: XCTestCase {
    func testModernBitcoinFormattingUsesSpaceGrouping() {
        XCTAssertEqual(
            CalculatorWidgetFormatter.formatBitcoinValue("1800000000", displayUnit: .modern),
            "1 800 000 000"
        )
    }

    func testClassicBitcoinFormattingUsesEightDecimalPlaceholder() {
        XCTAssertEqual(CalculatorWidgetFormatter.formatBitcoinPlaceholder("", displayUnit: .classic), ".00000000")
        XCTAssertEqual(CalculatorWidgetFormatter.formatBitcoinPlaceholder("1", displayUnit: .classic), ".00000000")
        XCTAssertEqual(CalculatorWidgetFormatter.formatBitcoinPlaceholder("1.", displayUnit: .classic), "00000000")
        XCTAssertEqual(CalculatorWidgetFormatter.formatBitcoinPlaceholder("1.2", displayUnit: .classic), "0000000")
        XCTAssertEqual(CalculatorWidgetFormatter.formatBitcoinPlaceholder("1.23456789", displayUnit: .classic), "")
        XCTAssertEqual(CalculatorWidgetFormatter.formatBitcoinPlaceholder("1000", displayUnit: .modern), "")
    }

    func testFiatFormattingUsesCommaGroupingAndPlaceholderZero() {
        XCTAssertEqual(CalculatorWidgetFormatter.formatFiatValue("82209.8"), "82,209.8")
        XCTAssertEqual(CalculatorWidgetFormatter.formatFiatPlaceholder("82209.8"), "0")
    }

    func testCalculatorNumberPadDecimalSeparatorAlwaysUsesPeriod() {
        XCTAssertEqual(CalculatorWidgetFormatter.numberPadDecimalSeparator(), ".")
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

    func testNumberPadClearRemovesRawValue() {
        let next = CalculatorWidgetFormatter.applyNumberPadInput(
            rawValue: "1000.50",
            key: "clear",
            maxDecimalPlaces: CalculatorWidgetFormatter.fiatDecimalPlaces
        )

        XCTAssertEqual(next, "")
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

    func testLocalizedCommaDecimalKeyAppendsCalculatorDecimal() {
        let locale = Locale(identifier: "fr_BE")
        let value = CalculatorWidgetFormatter.applyNumberPadInput(
            rawValue: "1",
            key: ",",
            maxDecimalPlaces: CalculatorWidgetFormatter.fiatDecimalPlaces,
            locale: locale
        )

        XCTAssertEqual(value, "1.")
    }

    func testPeriodDecimalKeyWorksForLocalizedFiatInput() {
        let locale = Locale(identifier: "fr_BE")
        let value = CalculatorWidgetFormatter.applyNumberPadInput(
            rawValue: "1",
            key: ".",
            maxDecimalPlaces: CalculatorWidgetFormatter.fiatDecimalPlaces,
            locale: locale
        )

        XCTAssertEqual(value, "1.")
    }

    func testPersistedFiatOnlyValuesUseFiatAsSource() {
        let values = CalculatorWidgetValues(bitcoinValue: "", fiatValue: "12.34")

        XCTAssertTrue(values.shouldRefreshBitcoinFromFiat)
    }

    func testFiatActiveInputStaysRefreshSourceWhenBothValuesExist() {
        let values = CalculatorWidgetValues(bitcoinValue: "10000", fiatValue: "12.34")

        XCTAssertEqual(values.refreshSource(activeInput: .fiat), .fiat)
    }

    func testBitcoinActiveInputStaysRefreshSourceWhenFiatOnlyWouldOtherwiseWin() {
        let values = CalculatorWidgetValues(bitcoinValue: "", fiatValue: "12.34")

        XCTAssertEqual(values.refreshSource(activeInput: .bitcoin), .bitcoin)
    }

    func testEmptyFiatActiveInputSkipsRefreshSource() {
        let values = CalculatorWidgetValues(bitcoinValue: "10000", fiatValue: "")

        XCTAssertNil(values.refreshSource(activeInput: .fiat))
    }

    func testRefreshSourceFallsBackToFiatOnlyValue() {
        let values = CalculatorWidgetValues(bitcoinValue: "", fiatValue: "12.34")

        XCTAssertEqual(values.refreshSource(activeInput: nil), .fiat)
    }

    func testRefreshSourceFallsBackToBitcoinWhenBothValuesExist() {
        let values = CalculatorWidgetValues(bitcoinValue: "10000", fiatValue: "12.34")

        XCTAssertEqual(values.refreshSource(activeInput: nil), .bitcoin)
    }

    func testPreviewPreservesPersistedFiatOnlyValue() {
        let values = CalculatorWidgetValues(bitcoinValue: "", fiatValue: "12.34")

        XCTAssertEqual(CalculatorWidgetPreviewLogic.previewFiatValue(saved: values, recalculatedFiatValue: ""), "12.34")
    }

    func testPreviewUsesRecalculatedFiatWhenBitcoinValueExists() {
        let values = CalculatorWidgetValues(bitcoinValue: "10000", fiatValue: "12.34")

        XCTAssertEqual(CalculatorWidgetPreviewLogic.previewFiatValue(saved: values, recalculatedFiatValue: "10.00"), "10.00")
    }

    func testPreviewKeepsPersistedZeroBitcoinValueVisible() {
        let values = CalculatorWidgetValues(bitcoinValue: "0", fiatValue: "0.00")

        XCTAssertEqual(CalculatorWidgetPreviewLogic.previewBitcoinValue(saved: values, displayUnit: .modern), "0")
        XCTAssertEqual(CalculatorWidgetPreviewLogic.previewBitcoinValue(saved: values, displayUnit: .classic), "0")
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

    func testFiatConversionKeepsZeroSatsVisible() {
        XCTAssertEqual(CalculatorWidgetFormatter.fiatConversionBitcoinValue(0, displayUnit: .modern), "0")
        XCTAssertEqual(CalculatorWidgetFormatter.fiatConversionBitcoinValue(0, displayUnit: .classic), "0")
    }

    func testFiatConversionReturnsNilWhenRateUnavailable() {
        let sats = CalculatorWidgetFormatter.convertedSatsFromFiat("12.34") { _ in nil }

        XCTAssertNil(sats)
    }

    func testZeroFiatConversionDoesNotRequireRate() {
        let sats = CalculatorWidgetFormatter.convertedSatsFromFiat("0") { _ in nil }

        XCTAssertEqual(sats, 0)
    }

    func testClassicBitcoinRejectsValuesAboveSupply() {
        XCTAssertTrue(CalculatorWidgetFormatter.exceedsMaxBitcoin("21000000.00000001", displayUnit: .classic))
        XCTAssertFalse(CalculatorWidgetFormatter.exceedsMaxBitcoin("21000000", displayUnit: .classic))
    }
}
