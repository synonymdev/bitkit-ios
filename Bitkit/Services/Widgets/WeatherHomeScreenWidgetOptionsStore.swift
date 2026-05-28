import Foundation
import WidgetKit

/// Mirrors in-app Weather widget options into the App Group so the WidgetKit extension can read them,
/// and centralizes the WidgetKit reload trigger for the Weather home-screen widget.
enum WeatherHomeScreenWidgetOptionsStore {
    static let weatherHomeScreenWidgetKind = "BitkitWeatherWidget"

    private static let suiteName = "group.bitkit"
    private static let key = "home_screen_weather_widget_options_v1"

    static func save(_ options: WeatherWidgetOptions) {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(options)
        else { return }
        defaults.set(data, forKey: key)
    }

    static func load() -> WeatherWidgetOptions {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: key),
              let options = try? JSONDecoder().decode(WeatherWidgetOptions.self, from: data)
        else {
            return WeatherWidgetOptions()
        }
        return options
    }

    /// Call after updating options or cache so the home-screen widget timeline refreshes.
    /// No-op when running inside the widget extension itself (`appex`).
    static func reloadHomeScreenWidgetIfNeeded() {
        guard Bundle.main.bundleURL.pathExtension != "appex" else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: weatherHomeScreenWidgetKind)
    }
}

enum WeatherCurrencyAppGroupStore {
    private static let suiteName = "group.bitkit"
    private static let key = "home_screen_display_currency_code_v1"
    private static let symbolKey = "home_screen_display_currency_symbol_v1"
    static let fallbackCode = "USD"
    static let fallbackSymbol = "$"

    static func save(code: String, symbol: String) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.set(code, forKey: key)
        defaults.set(symbol, forKey: symbolKey)
    }

    static func load() -> String {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let code = defaults.string(forKey: key),
              !code.isEmpty
        else {
            return fallbackCode
        }
        return code
    }

    static func loadSymbol() -> String {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let symbol = defaults.string(forKey: symbolKey),
              !symbol.isEmpty
        else {
            return fallbackSymbol
        }
        return symbol
    }
}
