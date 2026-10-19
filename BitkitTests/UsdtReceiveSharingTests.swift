@testable import Bitkit
import CoreImage
import XCTest

final class UsdtReceiveSharingTests: XCTestCase {
    @MainActor
    func testShareTextContainsAddressNetworkAndExactOptionalAmount() {
        let address = "0x18503bD685aF84E6A7bC289898bAa1C3f5d8527E"
        for (network, amount) in [("Arbitrum One", ""), ("Arbitrum One", "1.234567"), ("Polygon", "3.5")] {
            let view = UsdtReceiveAddressContent(address: address, uri: "ethereum:token/transfer", network: network,
                                                 amount: amount, onEdit: {}, onNetwork: {})
            let networkTitle = t("usdt__receive_network", variables: ["network": network])
            let expected = "\(networkTitle)\n\(address)" + (amount.isEmpty ? "" : "\n\(amount) USDT")
            XCTAssertEqual(view.shareText, expected)
        }
    }

    @MainActor
    func testSharedQrEncodesOriginalPaymentUri() throws {
        let address = "0x18503bD685aF84E6A7bC289898bAa1C3f5d8527E"
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        for uri in [
            "ethereum:0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9@42161/transfer?address=\(address)",
            "ethereum:0xc2132D05D31c914a87C6611C10748AEb04B58e8F@137/transfer?address=\(address)&uint256=1234567",
            "bitcoin:bcrt1qexample?amount=0.001",
            "lightning:lnbcrt1000n1example",
        ] {
            let image = try XCTUnwrap(QR.shareImage(content: uri))
            let features = try detector.features(in: XCTUnwrap(CIImage(image: image)))
            XCTAssertEqual((features.first as? CIQRCodeFeature)?.messageString, uri)
        }
    }
}
