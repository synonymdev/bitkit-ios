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

        if current < 2 {
            migration2()
            UserDefaults.standard.set(2, forKey: versionKey)
        }
    }

    /// Migration 1: Move suggestions into widgets
    private static func migration1() {
        let key = "savedWidgets"
        guard let data = UserDefaults.standard.data(forKey: key), !data.isEmpty else { return }
        guard var list = try? JSONDecoder().decode([SavedWidget].self, from: data) else { return }
        if list.contains(where: { $0.type == .suggestions }) {
            return
        }
        list.insert(SavedWidget(type: .suggestions), at: 0)
        if let encoded = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    /// Migration 2: Restore the Paykit-on default for wallets that never set Paykit up.
    /// Wallet wipes on 2.3.2 to 2.5.0 stored Paykit off; an off with any Paykit footprint is kept as an opt-out.
    private static func migration2() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: PaykitFeatureFlags.uiEnabledKey) as? Bool == false else { return }

        let hasPaykitFootprint = PaykitFeatureFlags.hasPublicPublishedState(defaults: defaults) ||
            PaykitFeatureFlags.hasPrivatePublishedState(defaults: defaults) ||
            defaults.bool(forKey: PublicPaykitService.cleanupPendingKey) ||
            defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey) ||
            hasStoredPubkyIdentity()
        guard !hasPaykitFootprint else { return }

        defaults.removeObject(forKey: PaykitFeatureFlags.uiEnabledKey)
    }

    private static func hasStoredPubkyIdentity() -> Bool {
        do {
            return try Keychain.load(key: .pubkySecretKey) != nil || Keychain.load(key: .paykitSession) != nil
        } catch {
            return true
        }
    }
}
