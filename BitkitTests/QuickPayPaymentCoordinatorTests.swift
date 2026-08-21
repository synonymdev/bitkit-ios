@testable import Bitkit
import LDKNode
import XCTest

@MainActor
final class QuickPayPaymentCoordinatorTests: XCTestCase {
    func testClassifyDuplicatePayment() {
        XCTAssertEqual(
            QuickPayPaymentCoordinator.classify(NodeError.DuplicatePayment(message: "dup")),
            .duplicatePayment
        )
    }

    func testClassifyInvalidInvoiceAsPreDispatch() {
        XCTAssertEqual(
            QuickPayPaymentCoordinator.classify(NodeError.InvalidInvoice(message: "bad")),
            .preDispatchRejection
        )
    }

    func testClassifyPersistenceAsAmbiguous() {
        XCTAssertEqual(
            QuickPayPaymentCoordinator.classify(NodeError.PersistenceFailed(message: "io")),
            .ambiguous
        )
    }
}
