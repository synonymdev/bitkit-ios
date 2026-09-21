@testable import Bitkit
import XCTest

/// Regression + correctness tests for RGS and Electrum server URL validation.
/// The long-dotless-host cases guard against catastrophic regex backtracking (ReDoS)
/// that previously froze the settings screens.
final class SettingsUrlValidationTests: XCTestCase {
    @MainActor
    func testRgsUrlValidationRejectsLongDotlessHostQuickly() {
        let settings = SettingsViewModel.shared
        let longHost = "https://" + String(repeating: "a", count: 40)

        let start = Date()
        let isValid = settings.isValidRgsUrl(longHost)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(isValid)
        XCTAssertLessThan(elapsed, 0.1, "RGS validation must not catastrophically backtrack")
    }

    @MainActor
    func testElectrumUrlValidationRejectsLongDotlessHostQuickly() {
        let settings = SettingsViewModel.shared
        let longHost = String(repeating: "a", count: 40)

        let start = Date()
        let isValid = settings.isValidElectrumURL(longHost)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(isValid)
        XCTAssertLessThan(elapsed, 0.1, "Electrum validation must not catastrophically backtrack")
    }

    @MainActor
    func testRgsUrlValidationAcceptsValidUrls() {
        let settings = SettingsViewModel.shared

        XCTAssertTrue(settings.isValidRgsUrl(""), "empty URL disables RGS and is valid")
        XCTAssertTrue(settings.isValidRgsUrl("https://rapidsync.lightningdevkit.org/snapshot"))
        XCTAssertTrue(settings.isValidRgsUrl("https://1.2.3.4:443"))
    }

    @MainActor
    func testRgsUrlValidationRejectsInvalidUrls() {
        let settings = SettingsViewModel.shared

        XCTAssertFalse(settings.isValidRgsUrl("http://example.com"), "non-https is rejected")
        XCTAssertFalse(settings.isValidRgsUrl("https://"), "missing host is rejected")
    }

    @MainActor
    func testElectrumUrlValidationAcceptsValidHosts() {
        let settings = SettingsViewModel.shared

        XCTAssertTrue(settings.isValidElectrumURL("electrum.blockstream.info"))
        XCTAssertTrue(settings.isValidElectrumURL("1.2.3.4"))
        XCTAssertTrue(settings.isValidElectrumURL("myhost.local"))
    }

    @MainActor
    func testElectrumUrlValidationRejectsBareDotlessHost() {
        let settings = SettingsViewModel.shared

        XCTAssertFalse(settings.isValidElectrumURL("foobar"))
    }
}
