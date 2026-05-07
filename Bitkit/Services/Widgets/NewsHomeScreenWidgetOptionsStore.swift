import Foundation
import WidgetKit

/// Mirrors in-app news widget options into the App Group so the WidgetKit extension can read them,
/// and centralizes the WidgetKit reload trigger for the news home-screen widget.
enum NewsHomeScreenWidgetOptionsStore {
    /// WidgetKit `kind` for the home-screen news widget (must match `BitkitNewsWidget`).
    static let newsHomeScreenWidgetKind = "BitkitNewsWidget"

    private static let suiteName = "group.bitkit"
    private static let key = "home_screen_news_widget_options_v1"

    static func save(_ options: NewsWidgetOptions) {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(options)
        else { return }
        defaults.set(data, forKey: key)
    }

    static func load() -> NewsWidgetOptions {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: key),
              let options = try? JSONDecoder().decode(NewsWidgetOptions.self, from: data)
        else {
            return NewsWidgetOptions()
        }
        return options
    }

    /// Call after updating options or cache so the home-screen widget timeline refreshes.
    /// No-op when running inside the widget extension itself (`appex`).
    static func reloadHomeScreenWidgetIfNeeded() {
        guard Bundle.main.bundleURL.pathExtension != "appex" else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: newsHomeScreenWidgetKind)
    }
}
