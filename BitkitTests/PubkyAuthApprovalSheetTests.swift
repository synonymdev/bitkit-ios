@testable import Bitkit
import XCTest

final class PubkyAuthApprovalSheetTests: XCTestCase {
    func testResolvePubkyApprovalLocalAuthModePrefersPinWhenPinEnabled() {
        let mode = resolvePubkyApprovalLocalAuthMode(
            isPinEnabled: true,
            isBiometricEnabled: true,
            isBiometrySupported: true
        )

        XCTAssertEqual(mode, .authCheck)
    }

    func testResolvePubkyApprovalLocalAuthModeUsesBiometricsWhenPinDisabled() {
        let mode = resolvePubkyApprovalLocalAuthMode(
            isPinEnabled: false,
            isBiometricEnabled: true,
            isBiometrySupported: true
        )

        XCTAssertEqual(mode, .biometrics)
    }

    func testResolvePubkyApprovalLocalAuthModeUsesNoneWhenBiometricsDisabled() {
        let mode = resolvePubkyApprovalLocalAuthMode(
            isPinEnabled: false,
            isBiometricEnabled: false,
            isBiometrySupported: true
        )

        XCTAssertEqual(mode, .none)
    }

    func testResolvePubkyApprovalLocalAuthModeUsesNoneWhenBiometricsUnavailable() {
        let mode = resolvePubkyApprovalLocalAuthMode(
            isPinEnabled: false,
            isBiometricEnabled: true,
            isBiometrySupported: false
        )

        XCTAssertEqual(mode, .none)
    }
}
