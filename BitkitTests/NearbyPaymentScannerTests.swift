@testable import Bitkit
import XCTest

@MainActor
final class NearbyPaymentScannerTests: XCTestCase {
    func testStoppingRevokesARequestStillBeingHandled() async {
        let scanner = NearbyPaymentScanner()
        let handed = expectation(description: "Request handed to the scanner's owner")
        var release: CheckedContinuation<Void, Never>?
        var isCurrent: (() -> Bool)?
        scanner.start { _, check in
            isCurrent = check
            await withCheckedContinuation {
                release = $0
                handed.fulfill()
            }
            return check()
        }

        scanner.deliverForTesting("bitcoin:bcrt1qexample")
        await fulfillment(of: [handed], timeout: 2)
        XCTAssertEqual(isCurrent?(), true)

        // The app goes inactive (Control Center) while the request is decoding, then comes back.
        scanner.stop()
        XCTAssertEqual(isCurrent?(), false, "A stopped scanner's request must not route")
        scanner.start { _, _ in false }
        XCTAssertEqual(isCurrent?(), false, "Scanning again must not revive the earlier request")
        release?.resume()
    }

    func testARequestDeliveredJustBeforeStoppingReachesNoHandler() async {
        let scanner = NearbyPaymentScanner()
        var handled: [String] = []
        scanner.start { request, _ in
            handled.append(request)
            return false
        }

        // The read completes, then the scene goes inactive before the delivery task runs.
        scanner.deliverForTesting("pubkyauth://signin")
        scanner.stop()
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        XCTAssertEqual(handled, [], "A revoked request must not reach the handler or show its error")
    }
}
