@testable import Bitkit
import XCTest

final class Bip21UtilsTests: XCTestCase {
    func testHardwareInvoiceWithAddressOnly() {
        XCTAssertEqual(
            Bip21Utils.hardwareInvoice(address: "bcrt1qreceive", amountSats: 0, message: ""),
            "bitcoin:bcrt1qreceive"
        )
    }

    func testHardwareInvoiceWithAmount() {
        XCTAssertEqual(
            Bip21Utils.hardwareInvoice(address: "bcrt1qreceive", amountSats: 123_456, message: ""),
            "bitcoin:bcrt1qreceive?amount=0.00123456"
        )
    }

    func testHardwareInvoiceEncodesMessage() {
        XCTAssertEqual(
            Bip21Utils.hardwareInvoice(address: "bcrt1qreceive", amountSats: 0, message: "Coffee & cake"),
            "bitcoin:bcrt1qreceive?message=Coffee%20%26%20cake"
        )
    }

    func testHardwareInvoiceWithAmountAndMessage() {
        XCTAssertEqual(
            Bip21Utils.hardwareInvoice(address: "bcrt1qreceive", amountSats: 21000, message: "Hardware receive"),
            "bitcoin:bcrt1qreceive?amount=0.00021&message=Hardware%20receive"
        )
    }
}
