@testable import Bitkit
import XCTest

final class AppDataMigrationsTests: XCTestCase {
    private let paykitKey = PaykitFeatureFlags.uiEnabledKey

    // MARK: - Upgrades from 2.x (schema 0 or 1)

    func testUpgradeWithoutStoredPaykitFlagShowsPaykit() throws {
        let defaults = try makeIsolatedDefaults()

        AppDataMigrations.run(defaults: defaults, hasStoredPubkyIdentity: { false })

        XCTAssertNil(defaults.object(forKey: paykitKey))
        XCTAssertTrue(isPaykitUIEnabled(defaults))
        XCTAssertEqual(defaults.integer(forKey: AppDataMigrations.versionKey), 5)
    }

    func testUpgradeWithPaykitOnKeepsPaykitOn() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(true, forKey: paykitKey)

        AppDataMigrations.run(defaults: defaults, hasStoredPubkyIdentity: { true })

        XCTAssertTrue(isPaykitUIEnabled(defaults))
    }

    func testUpgradeWithPaykitOffAndNoIdentityShowsPaykit() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(false, forKey: paykitKey)

        AppDataMigrations.run(defaults: defaults, hasStoredPubkyIdentity: { false })

        XCTAssertTrue(isPaykitUIEnabled(defaults))
    }

    func testUpgradeWithPaykitOffAndPubkyIdentityShowsPaykit() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(false, forKey: paykitKey)

        AppDataMigrations.run(defaults: defaults, hasStoredPubkyIdentity: { true })

        XCTAssertTrue(isPaykitUIEnabled(defaults))
    }

    func testUpgradeWithPaykitOffAndPendingCleanupShowsPaykitAndKeepsCleanup() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(false, forKey: paykitKey)
        defaults.set(true, forKey: PublicPaykitService.cleanupPendingKey)
        defaults.set(true, forKey: PrivatePaykitService.cleanupPendingKey)

        AppDataMigrations.run(defaults: defaults, hasStoredPubkyIdentity: { true })

        XCTAssertTrue(isPaykitUIEnabled(defaults))
        XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
        XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
    }

    // MARK: - Wallets already on 3.0.x (schema 2)

    func testWalletOnSchemaTwoWithPaykitOffShowsPaykit() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(2, forKey: AppDataMigrations.versionKey)
        defaults.set(false, forKey: paykitKey)

        AppDataMigrations.run(defaults: defaults, hasStoredPubkyIdentity: { true })

        XCTAssertTrue(isPaykitUIEnabled(defaults))
        XCTAssertEqual(defaults.integer(forKey: AppDataMigrations.versionKey), 5)
    }

    func testLegacyKeychainCleanupIsRetriedUntilItSucceeds() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(4, forKey: AppDataMigrations.versionKey)
        struct KeychainLocked: Error {}

        AppDataMigrations.run(defaults: defaults, hasStoredPubkyIdentity: { false }, deleteLegacyKeychainEntries: { throw KeychainLocked() })
        XCTAssertEqual(defaults.integer(forKey: AppDataMigrations.versionKey), 4, "A locked keychain is tried again on the next launch")

        var deletions = 0
        AppDataMigrations.run(defaults: defaults, hasStoredPubkyIdentity: { false }, deleteLegacyKeychainEntries: { deletions += 1 })
        XCTAssertEqual(deletions, 1)
        XCTAssertEqual(defaults.integer(forKey: AppDataMigrations.versionKey), 5)

        AppDataMigrations.run(defaults: defaults, hasStoredPubkyIdentity: { false }, deleteLegacyKeychainEntries: { deletions += 1 })
        XCTAssertEqual(deletions, 1, "The cleanup runs once")
    }

    // MARK: - After this migration

    func testDevSettingsOffAfterMigrationStaysOff() throws {
        let defaults = try makeIsolatedDefaults()
        AppDataMigrations.run(defaults: defaults, hasStoredPubkyIdentity: { true })
        defaults.set(false, forKey: paykitKey)

        AppDataMigrations.run(defaults: defaults, hasStoredPubkyIdentity: { true })

        XCTAssertFalse(isPaykitUIEnabled(defaults))
    }

    private func isPaykitUIEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: paykitKey) as? Bool ?? PaykitFeatureFlags.uiEnabledByDefault
    }

    func testPublicSharingUpgradeRequiresNewConsentAndQuarantinesReceiveAddress() throws {
        for privateSharing in [false, true] {
            let defaults = try makeIsolatedDefaults()
            defaults.set(3, forKey: AppDataMigrations.versionKey)
            defaults.set(true, forKey: PublicPaykitService.publishingEnabledKey)
            defaults.set(privateSharing, forKey: PrivatePaykitService.publishingEnabledKey)
            defaults.set(true, forKey: ContactPaymentsService.confirmedPreferenceKey)
            defaults.set("published-address", forKey: "onchainAddress")
            defaults.set("public-invoice", forKey: "publicPaykitBolt11")

            AppDataMigrations.run(defaults: defaults, hasStoredPubkyIdentity: { true })

            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
            XCTAssertEqual(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey), privateSharing)
            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
            XCTAssertTrue(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey))
            XCTAssertNil(defaults.string(forKey: "onchainAddress"))
            XCTAssertNil(defaults.string(forKey: "publicPaykitBolt11"))
            XCTAssertEqual(defaults.stringArray(forKey: PrivatePaykitAddressReservationStore.legacyPublicAddressesKey), ["published-address"])

            defaults.set(true, forKey: PublicPaykitService.publishingEnabledKey)
            defaults.set("ordinary-address", forKey: "onchainAddress")
            AppDataMigrations.run(defaults: defaults, hasStoredPubkyIdentity: { true })
            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
            XCTAssertEqual(defaults.string(forKey: "onchainAddress"), "ordinary-address")
        }
    }

    func testWalletWithoutPublicationKeepsItsReceiveAddressDuringUpgrade() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set("ordinary-address", forKey: "onchainAddress")
        AppDataMigrations.run(defaults: defaults, hasStoredPubkyIdentity: { false })
        XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
        XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
        XCTAssertNil(defaults.stringArray(forKey: PrivatePaykitAddressReservationStore.legacyPublicAddressesKey))
        XCTAssertEqual(defaults.string(forKey: "onchainAddress"), "ordinary-address")
        XCTAssertNil(defaults.data(forKey: "backupStatuses"))
    }

    func testLegacyConsentOrPendingRemovalStillQueuesPublicCleanup() throws {
        for evidenceKey in [ContactPaymentsService.confirmedPreferenceKey, PublicPaykitService.cleanupPendingKey] {
            let defaults = try makeIsolatedDefaults()
            defaults.set(3, forKey: AppDataMigrations.versionKey)
            defaults.set(true, forKey: evidenceKey)
            defaults.set("legacy-public-address", forKey: "onchainAddress")
            AppDataMigrations.run(defaults: defaults, hasStoredPubkyIdentity: { true })
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
            XCTAssertEqual(defaults.stringArray(forKey: PrivatePaykitAddressReservationStore.legacyPublicAddressesKey), ["legacy-public-address"])
        }
    }
}
