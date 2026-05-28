import Foundation

/// Stores the latest calculator values for Bitkit's in-app widget row and preview screen.
enum CalculatorWidgetOptionsStore {
    private static let key = "calculator_widget_values_v1"

    static func save(_ values: CalculatorWidgetValues) {
        guard let data = try? JSONEncoder().encode(values)
        else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> CalculatorWidgetValues {
        guard let data = UserDefaults.standard.data(forKey: key),
              let values = try? JSONDecoder().decode(CalculatorWidgetValues.self, from: data)
        else {
            return CalculatorWidgetValues()
        }
        return values
    }
}
