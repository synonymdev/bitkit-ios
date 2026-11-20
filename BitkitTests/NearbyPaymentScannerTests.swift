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
}
