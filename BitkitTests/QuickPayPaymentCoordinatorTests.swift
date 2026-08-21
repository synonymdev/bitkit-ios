@testable import Bitkit
import LDKNode
import XCTest

@MainActor
final class QuickPayPaymentCoordinatorTests: XCTestCase {
    func testDuplicatePaymentIsHardReject() {
        XCTAssertTrue(QuickPayPaymentCoordinator.isHardReject(NodeError.DuplicatePayment(message: "dup")))
    }

    func testInvalidInvoiceIsHardReject() {
        XCTAssertTrue(QuickPayPaymentCoordinator.isHardReject(NodeError.InvalidInvoice(message: "bad")))
    }

    func testPersistenceIsNotHardReject() {
        XCTAssertFalse(QuickPayPaymentCoordinator.isHardReject(NodeError.PersistenceFailed(message: "io")))
    }
}
