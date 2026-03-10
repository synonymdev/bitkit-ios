import Foundation

/// Runs one-time app data migrations in order using a single schema version.
/// Add new migrations by adding a step in `run()` and bumping the version.
enum AppDataMigrations {
    private static let versionKey = "appDataSchemaVersion"

    /// Call once at app launch (before feature code loads migrated state).
    static func run() {
        let current = UserDefaults.standard.integer(forKey: versionKey)

        if current < 1 {
            migration1()
            UserDefaults.standard.set(1, forKey: versionKey)
        }
    }

    /// Migration 1: Move suggestions into widgets
    private static func migration1() {
        let key = "savedWidgets"
        guard let data = UserDefaults.standard.data(forKey: key), !data.isEmpty else { return }
        guard var list = try? JSONDecoder().decode([SavedWidget].self, from: data) else { return }
        if list.contains(where: { $0.type == .suggestions }) { return }
        list.insert(SavedWidget(type: .suggestions), at: 0)
        if let encoded = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }
}
