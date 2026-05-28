@testable import Bitkit
import XCTest

/// Regression coverage for the shared fiat formatting helpers used by both the app and the
/// WidgetKit extension, plus the App Group symbol sync. Guards against the home-screen weather
/// widget rendering the locale-disambiguated "US$" instead of "$".
final class FiatFormattingTests: XCTestCase {
    // MARK: - formatFiatAmount

    func testFormatFiatAmount_TwoFractionDigits() throws {
        XCTAssertEqual(try formatFiatAmount(XCTUnwrap(Decimal(string: "0.5"))), "0.50")
    }

    func testFormatFiatAmount_RoundsToTwoDigits() throws {
        XCTAssertEqual(try formatFiatAmount(XCTUnwrap(Decimal(string: "0.526"))), "0.53")
    }

    func testFormatFiatAmount_GroupsThousandsWithComma() throws {
        XCTAssertEqual(try formatFiatAmount(XCTUnwrap(Decimal(string: "1234.5"))), "1,234.50")
    }

    func testFormatFiatAmount_Zero() {
        XCTAssertEqual(formatFiatAmount(0), "0.00")
    }

    // MARK: - formatFiatWithSymbol

    func testFormatFiatWithSymbol_PrefixCurrency() {
        XCTAssertEqual(formatFiatWithSymbol(formatted: "0.52", symbol: "$", currencyCode: "USD"), "$0.52")
    }

    func testFormatFiatWithSymbol_PrefixCurrency_WithSpace() {
        XCTAssertEqual(formatFiatWithSymbol(formatted: "0.52", symbol: "$", currencyCode: "USD", withSpace: true), "$ 0.52")
    }

    func testFormatFiatWithSymbol_SuffixCurrency() {
        XCTAssertEqual(formatFiatWithSymbol(formatted: "0.52", symbol: "kr", currencyCode: "SEK"), "0.52kr")
    }

    func testFormatFiatWithSymbol_SuffixCurrency_WithSpace() {
        XCTAssertEqual(formatFiatWithSymbol(formatted: "0.52", symbol: "kr", currencyCode: "SEK", withSpace: true), "0.52 kr")
    }

    func testFormatFiatWithSymbol_PlaceholderDash() {
        XCTAssertEqual(formatFiatWithSymbol(formatted: "—", symbol: "$", currencyCode: "USD", withSpace: true), "$ —")
    }

    // MARK: - Regression guard: never "US$"

    func testUsdFormatting_UsesDollarSignNotExtendedSymbol() throws {
        let amount = try formatFiatAmount(XCTUnwrap(Decimal(string: "0.52")))
        let result = formatFiatWithSymbol(formatted: amount, symbol: "$", currencyCode: "USD", withSpace: true)
        XCTAssertEqual(result, "$ 0.52")
        XCTAssertFalse(result.contains("US$"), "Weather widget must show \"$\", never the disambiguated \"US$\"")
    }

    // MARK: - WeatherCurrencyAppGroupStore symbol sync

    private static let suiteName = "group.bitkit"
    private static let codeKey = "home_screen_display_currency_code_v1"
    private static let symbolKey = "home_screen_display_currency_symbol_v1"

    private var savedCode: String?
    private var savedSymbol: String?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults(suiteName: Self.suiteName)
        savedCode = defaults?.string(forKey: Self.codeKey)
        savedSymbol = defaults?.string(forKey: Self.symbolKey)
    }

    override func tearDown() {
        let defaults = UserDefaults(suiteName: Self.suiteName)
        if let savedCode { defaults?.set(savedCode, forKey: Self.codeKey) } else { defaults?.removeObject(forKey: Self.codeKey) }
        if let savedSymbol { defaults?.set(savedSymbol, forKey: Self.symbolKey) } else { defaults?.removeObject(forKey: Self.symbolKey) }
        super.tearDown()
    }

    func testStore_RoundTripsCodeAndSymbol() {
        WeatherCurrencyAppGroupStore.save(code: "EUR", symbol: "€")
        XCTAssertEqual(WeatherCurrencyAppGroupStore.load(), "EUR")
        XCTAssertEqual(WeatherCurrencyAppGroupStore.loadSymbol(), "€")
    }

    func testStore_LoadSymbolFallsBackOnEmpty() {
        WeatherCurrencyAppGroupStore.save(code: "USD", symbol: "")
        XCTAssertEqual(WeatherCurrencyAppGroupStore.loadSymbol(), WeatherCurrencyAppGroupStore.fallbackSymbol)
        XCTAssertEqual(WeatherCurrencyAppGroupStore.fallbackSymbol, "$")
    }

    func testStore_PreservesBackendSymbolForUsd() {
        // The app syncs FxRate.currencySymbol ("$" for USD); the widget must read it back verbatim.
        WeatherCurrencyAppGroupStore.save(code: "USD", symbol: "$")
        XCTAssertEqual(WeatherCurrencyAppGroupStore.loadSymbol(), "$")
    }
}
