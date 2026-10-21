import Foundation

enum PaykitFeatureFlags {
    static let uiEnabledKey = "paykitUiEnabled"
    static let uiEnabledByDefault = true

    static var isUIAvailable: Bool {
        #if FEATURE_PAYKIT_UI_DISABLED
            false
        #else
            true
        #endif
    }

    static var isUIEnabled: Bool {
        isUIAvailable && (UserDefaults.standard.object(forKey: uiEnabledKey) as? Bool ?? uiEnabledByDefault)
    }

    static func hasPublicPublishedState(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: PublicPaykitService.publishingEnabledKey) ||
            defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey) ||
            !(defaults.string(forKey: "publicPaykitBolt11") ?? "").isEmpty
    }

    static func hasPrivatePublishedState(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey)
    }

    static func enforceBuildAvailability(defaults: UserDefaults = .standard, isUIEnabled: Bool = Self.isUIEnabled) {
        let hasPublicPublishedState = Self.hasPublicPublishedState(defaults: defaults)
        let hasPrivatePublishedState = Self.hasPrivatePublishedState(defaults: defaults)
        let hasPublishedState = hasPublicPublishedState ||
            hasPrivatePublishedState ||
            defaults.bool(forKey: PublicPaykitService.cleanupPendingKey) ||
            defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey)
        guard !isUIEnabled, hasPublishedState else { return }

        defaults.set(false, forKey: uiEnabledKey)
        defaults.set(false, forKey: ContactPaymentsService.confirmedPreferenceKey)
        defaults.set(false, forKey: PublicPaykitService.publishingEnabledKey)
        defaults.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.removeObject(forKey: "publicPaykitBolt11")
        defaults.removeObject(forKey: "publicPaykitBolt11PaymentHash")
        defaults.removeObject(forKey: "publicPaykitBolt11ExpiresAt")

        if hasPublicPublishedState {
            defaults.set(true, forKey: PublicPaykitService.cleanupPendingKey)
        }
        if hasPrivatePublishedState {
            defaults.set(true, forKey: PrivatePaykitService.cleanupPendingKey)
        }
    }
}
