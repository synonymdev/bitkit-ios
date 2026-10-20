@testable import Bitkit
import CoreImage
import SwiftUI
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
    func testQrLogoPreservesSquareLayoutInTallContainer() {
        for logo: String? in [nil, "btc", "tether-circle"] {
            let host = UIHostingController(rootView: QR(content: "bitcoin:bcrt1qexample", imageAsset: logo))
            for width: CGFloat in [140, 343] {
                let size = host.sizeThatFits(in: CGSize(width: width, height: 600))
                XCTAssertEqual(size.width, width, accuracy: 0.5)
                XCTAssertEqual(size.height, width, accuracy: 0.5, "Logo must not add vertical space below the QR")
            }
        }
    }

    @MainActor
    func testCompactQrWithLogoRemainsScannable() async throws {
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        defer { previousWindow?.makeKeyAndVisible() }
        for (uri, logo) in [
            (
                "ethereum:0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9@42161/transfer?address=0x1111111111111111111111111111111111111111",
                "tether-circle"
            ),
            ("bitcoin:bcrt1q5y0ejj4qxm2kahxdx3r6lqqcjr2wtj3agypvuu?amount=0.001", "btc"),
        ] {
            for height: CGFloat in [140, 343] {
                let host = UIHostingController(rootView: QR(content: uri, imageAsset: logo))
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 343, height: height)
                window.rootViewController = host
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
                var decoded: String?
                for _ in 0 ..< 40 {
                    try await Task.sleep(for: .milliseconds(50))
                    host.view.frame = window.bounds
                    host.view.layoutIfNeeded()
                    let image = UIGraphicsImageRenderer(size: window.bounds.size).image { context in
                        window.layer.render(in: context.cgContext)
                    }
                    let features = try detector.features(in: XCTUnwrap(CIImage(image: image)))
                    decoded = (features.first as? CIQRCodeFeature)?.messageString
                    if decoded == uri {
                        break
                    }
                }
                XCTAssertEqual(decoded, uri, "QR must remain scannable at height \(height)")
            }
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
