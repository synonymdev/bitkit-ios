@testable import Bitkit
import SwiftUI
import XCTest

final class AuthCheckBiometricPolicyTests: XCTestCase {
    func testStartsAuthenticationWhenLockedScreenBecomesActive() {
        XCTAssertTrue(
            AuthCheckBiometricPolicy.shouldStart(
                scenePhase: .active,
                isEnabled: true,
                hasActiveAttempt: false,
                attemptKind: .automatic,
                hasAutomaticallyAttempted: false
            )
        )
    }

    func testDoesNotStartAuthenticationWhileAppIsInactive() {
        for scenePhase in [ScenePhase.inactive, .background] {
            XCTAssertFalse(
                AuthCheckBiometricPolicy.shouldStart(
                    scenePhase: scenePhase,
                    isEnabled: true,
                    hasActiveAttempt: false,
                    attemptKind: .automatic,
                    hasAutomaticallyAttempted: false
                )
            )
        }
    }

    func testDoesNotStartAuthenticationWhenDisabledOrAlreadyRunning() {
        XCTAssertFalse(
            AuthCheckBiometricPolicy.shouldStart(
                scenePhase: .active,
                isEnabled: false,
                hasActiveAttempt: false,
                attemptKind: .automatic,
                hasAutomaticallyAttempted: false
            )
        )
        XCTAssertFalse(
            AuthCheckBiometricPolicy.shouldStart(
                scenePhase: .active,
                isEnabled: true,
                hasActiveAttempt: true,
                attemptKind: .automatic,
                hasAutomaticallyAttempted: false
            )
        )
    }

    func testDoesNotAutomaticallyRetryAfterFailedAttempt() {
        XCTAssertFalse(
            AuthCheckBiometricPolicy.shouldStart(
                scenePhase: .active,
                isEnabled: true,
                hasActiveAttempt: false,
                attemptKind: .automatic,
                hasAutomaticallyAttempted: true
            )
        )
    }

    func testAllowsUserToRetryBiometricsAfterFailedAutomaticAttempt() {
        XCTAssertTrue(
            AuthCheckBiometricPolicy.shouldStart(
                scenePhase: .active,
                isEnabled: true,
                hasActiveAttempt: false,
                attemptKind: .manual,
                hasAutomaticallyAttempted: true
            )
        )
    }

    func testCancelsAuthenticationOnlyWhenAppEntersBackground() {
        XCTAssertTrue(AuthCheckBiometricPolicy.shouldCancel(scenePhase: .background))
        XCTAssertFalse(AuthCheckBiometricPolicy.shouldCancel(scenePhase: .inactive))
        XCTAssertFalse(AuthCheckBiometricPolicy.shouldCancel(scenePhase: .active))
    }

    func testStartsAuthenticationAfterCompletedAttemptAndReopeningLockedScreen() {
        var hasAutomaticallyAttempted = true

        if AuthCheckBiometricPolicy.shouldCancel(scenePhase: .background) {
            hasAutomaticallyAttempted = false
        }

        XCTAssertTrue(
            AuthCheckBiometricPolicy.shouldStart(
                scenePhase: .active,
                isEnabled: true,
                hasActiveAttempt: false,
                attemptKind: .automatic,
                hasAutomaticallyAttempted: hasAutomaticallyAttempted
            )
        )
    }
}
