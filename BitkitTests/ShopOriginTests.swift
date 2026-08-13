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
        XCTAssertTrue(script.contains("addEventListener('message'"))
        XCTAssertTrue(script.contains("bitrefill.com"))
        XCTAssertFalse(script.contains("window.postMessage ="))
    }
}
