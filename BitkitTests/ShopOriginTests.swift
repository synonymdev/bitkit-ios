@testable import Bitkit
import XCTest

final class ShopOriginTests: XCTestCase {
    func testHttpsBitrefillHostsAreAllowed() {
        XCTAssertTrue(ShopOrigin.isAllowed(URL(string: "https://embed.bitrefill.com")))
        XCTAssertTrue(ShopOrigin.isAllowed(URL(string: "https://embed.bitrefill.com/gift-cards")))
        XCTAssertTrue(ShopOrigin.isAllowed(URL(string: "https://bitrefill.com")))
        XCTAssertTrue(ShopOrigin.isAllowed(URL(string: "https://www.bitrefill.com/esims")))
        XCTAssertTrue(ShopOrigin.isAllowedHost("embed.bitrefill.com"))
        XCTAssertTrue(ShopOrigin.isAllowedHost("BITREFILL.COM"))
    }

    func testNonBitrefillAndNonHttpsOriginsAreRejected() {
        XCTAssertFalse(ShopOrigin.isAllowed(nil as URL?))
        XCTAssertFalse(ShopOrigin.isAllowed(URL(string: "https://evil.example")))
        XCTAssertFalse(ShopOrigin.isAllowed(URL(string: "https://bitrefill.com.evil.example")))
        XCTAssertFalse(ShopOrigin.isAllowed(URL(string: "https://notbitrefill.com")))
        XCTAssertFalse(ShopOrigin.isAllowed(URL(string: "http://embed.bitrefill.com")))
        XCTAssertFalse(ShopOrigin.isAllowed(URL(string: "javascript:alert(1)")))
        XCTAssertFalse(ShopOrigin.isAllowedHost("evil.example"))
        XCTAssertFalse(ShopOrigin.isAllowedHost(nil))
    }

    func testBridgeScriptChecksMessageOrigin() {
        let script = ShopOrigin.messageBridgeScript
        XCTAssertTrue(script.contains("if (!window.__bitkitShopBridgeInstalled)"))
        XCTAssertTrue(script.contains("addEventListener('message'"))
        XCTAssertTrue(script.contains("event.origin !== 'https://embed.bitrefill.com'"))
        XCTAssertFalse(script.contains("window.postMessage ="))
    }

    func testMessageSenderRequiresExactPaymentOriginInMainFrame() {
        XCTAssertTrue(
            ShopOrigin.isAllowedMessageSender(
                isMainFrame: true,
                scheme: "https",
                host: "embed.bitrefill.com",
                port: 0
            )
        )
        XCTAssertTrue(
            ShopOrigin.isAllowedMessageSender(
                isMainFrame: true,
                scheme: "HTTPS",
                host: "EMBED.BITREFILL.COM",
                port: 443
            )
        )
        XCTAssertFalse(
            ShopOrigin.isAllowedMessageSender(
                isMainFrame: false,
                scheme: "https",
                host: "embed.bitrefill.com",
                port: 0
            )
        )
        XCTAssertFalse(
            ShopOrigin.isAllowedMessageSender(
                isMainFrame: true,
                scheme: "http",
                host: "embed.bitrefill.com",
                port: 0
            )
        )
        XCTAssertFalse(
            ShopOrigin.isAllowedMessageSender(
                isMainFrame: true,
                scheme: "https",
                host: "www.bitrefill.com",
                port: 0
            )
        )
        XCTAssertFalse(
            ShopOrigin.isAllowedMessageSender(
                isMainFrame: true,
                scheme: "https",
                host: "embed.bitrefill.com",
                port: 8443
            )
        )
    }

    func testBitrefillCheckoutRestrictsMainFrameNavigation() {
        let checkout = "https://embed.bitrefill.com/gift-cards"
        XCTAssertTrue(ShopOrigin.shouldRestrictNavigation(initialUrl: checkout))
        XCTAssertTrue(
            ShopOrigin.shouldAllowMainFrameNavigation(
                to: URL(string: "https://www.bitrefill.com/esims"),
                initialUrl: checkout
            )
        )
        XCTAssertFalse(
            ShopOrigin.shouldAllowMainFrameNavigation(
                to: URL(string: "https://evil.example"),
                initialUrl: checkout
            )
        )
        XCTAssertFalse(
            ShopOrigin.shouldAllowMainFrameNavigation(
                to: URL(string: "https://btcmap.org/map"),
                initialUrl: checkout
            )
        )
    }

    func testBtcMapDiscoverAllowsNonBitrefillMainFrame() {
        let map = "https://btcmap.org/map"
        XCTAssertFalse(ShopOrigin.shouldRestrictNavigation(initialUrl: map))
        XCTAssertTrue(ShopOrigin.shouldAllowMainFrameNavigation(to: URL(string: map), initialUrl: map))
        XCTAssertTrue(
            ShopOrigin.shouldAllowMainFrameNavigation(
                to: URL(string: "https://btcmap.org/merchant/123"),
                initialUrl: map
            )
        )
    }
}
