@testable import Bitkit
import XCTest

final class PaykitFeatureFlagsTests: XCTestCase {
    func testAllowancesNeedDevModeAndTheFlagToDifferFromTheDefault() {
        for defaultValue in [true, false] {
            XCTAssertEqual(PaykitFeatureFlags.areAllowancesEnabled(isDevModeEnabled: false, override: nil, default: defaultValue), defaultValue)
            XCTAssertEqual(
                PaykitFeatureFlags.areAllowancesEnabled(isDevModeEnabled: false, override: !defaultValue, default: defaultValue),
                defaultValue
            )
            XCTAssertEqual(PaykitFeatureFlags.areAllowancesEnabled(isDevModeEnabled: true, override: nil, default: defaultValue), defaultValue)
            XCTAssertTrue(PaykitFeatureFlags.areAllowancesEnabled(isDevModeEnabled: true, override: true, default: defaultValue))
            XCTAssertFalse(PaykitFeatureFlags.areAllowancesEnabled(isDevModeEnabled: true, override: false, default: defaultValue))
        }
    }

    func testTurningDevModeOffFallsBackToTheDefault() {
        let override = !PaykitFeatureFlags.allowancesEnabledByDefault
        XCTAssertEqual(PaykitFeatureFlags.areAllowancesEnabled(isDevModeEnabled: true, override: override), override)
        XCTAssertEqual(
            PaykitFeatureFlags.areAllowancesEnabled(isDevModeEnabled: false, override: override),
            PaykitFeatureFlags.allowancesEnabledByDefault
        )
    }
}
