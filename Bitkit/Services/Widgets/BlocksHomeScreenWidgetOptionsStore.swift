import Foundation
import WidgetKit

/// Mirrors in-app Blocks widget options into the App Group so the WidgetKit extension can read them,
/// and centralizes the WidgetKit reload trigger for the Blocks home-screen widget.
enum BlocksHomeScreenWidgetOptionsStore {
    /// WidgetKit `kind` for the home-screen Blocks widget (must match `BitkitBlocksWidget`).
    static let blocksHomeScreenWidgetKind = "BitkitBlocksWidget"

    private static let suiteName = "group.bitkit"
    private static let key = "home_screen_blocks_widget_options_v1"

    static func save(_ options: BlocksWidgetOptions) {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(options)
        else { return }
        defaults.set(data, forKey: key)
    }

    static func load() -> BlocksWidgetOptions {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: key),
              let options = try? JSONDecoder().decode(BlocksWidgetOptions.self, from: data)
        else {
            return BlocksWidgetOptions()
        }
        return options
    }

    /// Call after updating options or cache so the home-screen widget timeline refreshes.
    /// No-op when running inside the widget extension itself (`appex`).
    static func reloadHomeScreenWidgetIfNeeded() {
        guard Bundle.main.bundleURL.pathExtension != "appex" else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: blocksHomeScreenWidgetKind)
    }
}
