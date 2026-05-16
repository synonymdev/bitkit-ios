import Foundation
import WidgetKit

/// Mirrors the latest calculator values into the App Group so the WidgetKit extension can render them,
/// and centralizes the WidgetKit reload trigger for the Calculator home-screen widget.
enum CalculatorHomeScreenWidgetOptionsStore {
    /// WidgetKit `kind` for the home-screen Calculator widget (must match `BitkitCalculatorWidget`).
    static let calculatorHomeScreenWidgetKind = "BitkitCalculatorWidget"

    private static let suiteName = "group.bitkit"
    private static let key = "home_screen_calculator_widget_values_v1"

    static func save(_ values: CalculatorWidgetValues) {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(values)
        else { return }
        defaults.set(data, forKey: key)
    }

    static func load() -> CalculatorWidgetValues {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode(CalculatorWidgetValues.self, from: data)
        else {
            return CalculatorWidgetValues()
        }
        return values
    }

    /// Call after updating values so the home-screen widget timeline refreshes.
    /// No-op when running inside the widget extension itself (`appex`).
    static func reloadHomeScreenWidgetIfNeeded() {
        guard Bundle.main.bundleURL.pathExtension != "appex" else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: calculatorHomeScreenWidgetKind)
    }
}
