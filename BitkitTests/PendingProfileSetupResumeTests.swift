@testable import Bitkit
import XCTest

final class PendingProfileSetupResumeTests: XCTestCase {
    func testResumeReadiness() {
        let cases: [(pending: Bool, paykitActive: Bool, authenticated: Bool, sheet: Bool, replacing: Bool, route: Route?,
                     expected: PendingProfileSetupResumeState)] = [
            (false, true, true, false, false, nil, .inactive),
            (false, false, false, true, true, .createProfile, .inactive),
            (true, false, true, false, false, nil, .waiting),
            (true, true, false, false, false, nil, .waiting),
            (true, true, true, true, false, nil, .waiting),
            (true, true, true, false, true, nil, .waiting),
            (true, true, true, false, false, .createProfile, .waiting),
            (true, true, true, false, false, nil, .ready),
            (true, true, true, false, false, .settings, .ready),
        ]

        for (index, testCase) in cases.enumerated() {
            XCTAssertEqual(
                resolvePendingProfileSetupResumeState(
                    isProfileSetupPending: testCase.pending,
                    isPaykitUIActive: testCase.paykitActive,
                    isAuthenticated: testCase.authenticated,
                    hasActiveSheet: testCase.sheet,
                    isReplacingSheet: testCase.replacing,
                    currentRoute: testCase.route
                ),
                testCase.expected,
                "Case \(index)"
            )
        }
    }

    func testWaitingPreservesResumeLatchUntilPendingSetupClears() {
        for alreadyResumed in [false, true] {
            var didResume = alreadyResumed
            let waiting = resolvePendingProfileSetupResumeState(
                isProfileSetupPending: true,
                isPaykitUIActive: true,
                isAuthenticated: true,
                hasActiveSheet: true,
                isReplacingSheet: false,
                currentRoute: nil
            )

            XCTAssertFalse(waiting.shouldResume(didResume: &didResume))
            XCTAssertEqual(didResume, alreadyResumed)
            XCTAssertEqual(PendingProfileSetupResumeState.ready.shouldResume(didResume: &didResume), !alreadyResumed)
            XCTAssertTrue(didResume)
            XCTAssertFalse(PendingProfileSetupResumeState.ready.shouldResume(didResume: &didResume))

            let inactive = resolvePendingProfileSetupResumeState(
                isProfileSetupPending: false,
                isPaykitUIActive: true,
                isAuthenticated: false,
                hasActiveSheet: false,
                isReplacingSheet: false,
                currentRoute: nil
            )
            XCTAssertFalse(inactive.shouldResume(didResume: &didResume))
            XCTAssertFalse(didResume)
            XCTAssertTrue(PendingProfileSetupResumeState.ready.shouldResume(didResume: &didResume))
        }
    }

    func testLeavingCreateProfileDoesNotResumeAgain() {
        var didResume = false
        var resumedRoutes: [Route] = []

        for route: Route? in [nil, .createProfile, nil, .settings] {
            let state = resolvePendingProfileSetupResumeState(
                isProfileSetupPending: true,
                isPaykitUIActive: true,
                isAuthenticated: true,
                hasActiveSheet: false,
                isReplacingSheet: false,
                currentRoute: route
            )
            if state.shouldResume(didResume: &didResume) {
                resumedRoutes.append(.createProfile)
            }
        }

        XCTAssertEqual(resumedRoutes, [.createProfile])
    }
}
