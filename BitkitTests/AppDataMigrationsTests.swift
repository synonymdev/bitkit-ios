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
        XCTAssertEqual(defaults.integer(forKey: AppDataMigrations.versionKey), 3)
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
        XCTAssertEqual(defaults.integer(forKey: AppDataMigrations.versionKey), 3)
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
}
