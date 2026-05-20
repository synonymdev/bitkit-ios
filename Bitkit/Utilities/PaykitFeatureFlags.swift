import Foundation

enum PaykitFeatureFlags {
    static let uiEnabledKey = "paykitUiEnabled"

    static var isUIAvailable: Bool {
        #if PAYKIT_UI_DISABLED
            false
        #else
            true
        #endif
    }

    static var isUIEnabled: Bool {
        isUIAvailable && UserDefaults.standard.bool(forKey: uiEnabledKey)
    }

    static func enforceBuildAvailability() {
        let defaults = UserDefaults.standard
        let hasPublishedState = defaults.bool(forKey: PublicPaykitService.publishingEnabledKey) ||
            defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey) ||
            defaults.bool(forKey: "hasConfirmedPublicPaykitEndpoints") ||
            !(defaults.string(forKey: "publicPaykitBolt11") ?? "").isEmpty

        guard !isUIEnabled, hasPublishedState else { return }

        defaults.set(false, forKey: uiEnabledKey)
        defaults.set(false, forKey: "hasConfirmedPublicPaykitEndpoints")
        defaults.set(false, forKey: PublicPaykitService.publishingEnabledKey)
        defaults.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.removeObject(forKey: "publicPaykitBolt11")
        defaults.removeObject(forKey: "publicPaykitBolt11PaymentHash")
        defaults.removeObject(forKey: "publicPaykitBolt11ExpiresAt")

        PrivatePaykitService.setContactSharingCleanupPending(true)
    }
}
