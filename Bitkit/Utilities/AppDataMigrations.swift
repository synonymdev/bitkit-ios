import Foundation

/// Runs one-time app data migrations in order using a single schema version.
/// Add new migrations by adding a step in `run()` and bumping the version.
enum AppDataMigrations {
    static let versionKey = "appDataSchemaVersion"

    /// Call once at app launch (before feature code loads migrated state).
    static func run(
        defaults: UserDefaults = .standard,
        hasStoredPubkyIdentity: () -> Bool = hasStoredPubkyIdentity
    ) {
        let current = defaults.integer(forKey: versionKey)

        if current < 1 {
            migration1(defaults: defaults)
            defaults.set(1, forKey: versionKey)
        }

        if current < 2 {
            migration2(defaults: defaults, hasStoredPubkyIdentity: hasStoredPubkyIdentity)
            defaults.set(2, forKey: versionKey)
        }

        if current < 3 {
            migration3(defaults: defaults)
            defaults.set(3, forKey: versionKey)
        }

        if current < 4 {
            migration4(defaults: defaults)
            defaults.set(4, forKey: versionKey)
        }
    }

    /// Migration 1: Move suggestions into widgets
    private static func migration1(defaults: UserDefaults) {
        let key = "savedWidgets"
        guard let data = defaults.data(forKey: key), !data.isEmpty,
              var list = try? JSONDecoder().decode([SavedWidget].self, from: data) else { return }
        if list.contains(where: { $0.type == .suggestions }) {
            return
        }
        list.insert(SavedWidget(type: .suggestions), at: 0)
        if let encoded = try? JSONEncoder().encode(list) {
            defaults.set(encoded, forKey: key)
        }
    }

    /// Migration 2: Restore the Paykit-on default for wallets that never set Paykit up.
    /// Wallet wipes on 2.3.0 to 2.5.1 stored Paykit off; an off with any Paykit footprint is kept as an opt-out.
    private static func migration2(defaults: UserDefaults, hasStoredPubkyIdentity: () -> Bool) {
        guard defaults.object(forKey: PaykitFeatureFlags.uiEnabledKey) as? Bool == false else { return }

        let hasPaykitFootprint = PaykitFeatureFlags.hasPublicPublishedState(defaults: defaults) ||
            PaykitFeatureFlags.hasPrivatePublishedState(defaults: defaults) ||
            defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey) ||
            defaults.bool(forKey: PublicPaykitService.cleanupPendingKey) ||
            defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey) ||
            hasStoredPubkyIdentity()
        guard !hasPaykitFootprint else { return }

        defaults.removeObject(forKey: PaykitFeatureFlags.uiEnabledKey)
    }

    /// Migration 3: Show Paykit to every wallet once, now that it is public.
    /// A stored off came from 2.x wipes or the Dev Settings switch; migration 2 kept it for wallets with a Pubky identity,
    /// which hid their profile. Like the Dev Settings "Enable", this only clears the flag. Later Dev Settings changes stay.
    private static func migration3(defaults: UserDefaults) {
        defaults.removeObject(forKey: PaykitFeatureFlags.uiEnabledKey)
    }

    private static func migration4(defaults: UserDefaults) {
        if PaykitFeatureFlags.hasPublicPublishedState(defaults: defaults) ||
            defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey) ||
            defaults.bool(forKey: PublicPaykitService.cleanupPendingKey)
        {
            defaults.set(true, forKey: PublicPaykitService.cleanupPendingKey)
            if let address = defaults.string(forKey: "onchainAddress"), !address.isEmpty {
                var addresses = Set(defaults.stringArray(forKey: PrivatePaykitAddressReservationStore.legacyPublicAddressesKey) ?? [])
                addresses.insert(address)
                defaults.set(addresses.sorted(), forKey: PrivatePaykitAddressReservationStore.legacyPublicAddressesKey)
                BackupService.markWalletBackupRequiredBeforeObservation(defaults: defaults)
                defaults.removeObject(forKey: "onchainAddress")
            }
        }
        // The combined contact setting did not express consent to public publication.
        defaults.set(false, forKey: PublicPaykitService.publishingEnabledKey)
        defaults.removeObject(forKey: "publicPaykitBolt11")
        defaults.removeObject(forKey: "publicPaykitBolt11PaymentHash")
        defaults.removeObject(forKey: "publicPaykitBolt11ExpiresAt")
    }

    private static func hasStoredPubkyIdentity() -> Bool {
        do {
            return try Keychain.load(key: .pubkySecretKey) != nil || Keychain.load(key: .paykitSession) != nil
        } catch {
            return true
        }
    }
}
