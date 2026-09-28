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

    // MARK: - isDuplicatedBip21 Tests

    func testIsDuplicatedBip21_ReturnsFalseForSingleValidBIP21URI() {
        let input = "bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq?amount=0.001&message=Bitkit"
        XCTAssertFalse(Bip21Utils.isDuplicatedBip21(input))
    }

    func testIsDuplicatedBip21_ReturnsTrueWhenBIP21URIIsDuplicated() {
        let first = "bitcoin:bcrt1qr289x0fhg62672e8urudfnxnsr8tcax64xk2vk?amount=0.0000002&message=Bitkit"
        let second = "bitcoin:bcrt1qr289x0fhg62672e8urudfnxnsr8tcax64xk2vk?amount=0.0000003&message=Bitkit"
        let input = first + second
        XCTAssertTrue(Bip21Utils.isDuplicatedBip21(input))
    }

    func testIsDuplicatedBip21_HandlesCaseInsensitiveBitcoinPrefix() {
        let first = "BITCOIN:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq?amount=0.001"
        let second = "bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq?amount=0.002"
        let input = first + second
        XCTAssertTrue(Bip21Utils.isDuplicatedBip21(input))
    }

    func testIsDuplicatedBip21_ReturnsFalseForNonBitcoinURIs() {
        let input = "lnbc500n1p3k9v3pp5kzmj..."
        XCTAssertFalse(Bip21Utils.isDuplicatedBip21(input))
    }

    func testIsDuplicatedBip21_ReturnsFalseForEmptyString() {
        XCTAssertFalse(Bip21Utils.isDuplicatedBip21(""))
    }

    func testIsDuplicatedBip21_HandlesMixedCaseDuplicatedURIs() {
        let first = "Bitcoin:bc1qaddr1?amount=0.001"
        let second = "BITCOIN:bc1qaddr2?amount=0.002"
        let input = first + second
        XCTAssertTrue(Bip21Utils.isDuplicatedBip21(input))
    }

    func testIsDuplicatedBip21_ReturnsFalseForPlainBitcoinAddress() {
        let input = "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq"
        XCTAssertFalse(Bip21Utils.isDuplicatedBip21(input))
    }

    func testIsDuplicatedBip21_ReturnsFalseForSingleBIP21WithLightningParam() {
        let input = "bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq?lightning=lnbc500n1p3k9v3pp5kzmj"
        XCTAssertFalse(Bip21Utils.isDuplicatedBip21(input))
    }
}
