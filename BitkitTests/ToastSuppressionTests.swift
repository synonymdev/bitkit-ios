@testable import Bitkit
import XCTest

final class ToastSuppressionTests: XCTestCase {
    func testToastsDisabledOnlyWhenDevModeAndToggleAreOn() throws {
        let defaults = try makeIsolatedDefaults()
        let key = ToastWindowManager.disableAllToastsKey

        defaults.set(true, forKey: "showDevSettings")
        XCTAssertFalse(ToastWindowManager.areToastsDisabled(defaults: defaults))

        defaults.set(true, forKey: key)
        XCTAssertTrue(ToastWindowManager.areToastsDisabled(defaults: defaults))

        defaults.set(false, forKey: "showDevSettings")
        XCTAssertFalse(ToastWindowManager.areToastsDisabled(defaults: defaults))
    }
}
