@testable import Bitkit
import XCTest

final class StringUtilitiesTests: XCTestCase {
    func testRemovingLightningSchemesStripsLnurlWithdrawPrefix() {
        let bech32 = "lnurl1example"
        XCTAssertEqual("lnurlw:\(bech32)".removingLightningSchemes(), bech32)
    }

    func testRemovingLightningSchemesIsCaseInsensitive() {
        let bech32 = "lnurl1example"
        XCTAssertEqual("LNURLW:\(bech32)".removingLightningSchemes(), bech32)
        XCTAssertEqual("LIGHTNING:lnbc1example".removingLightningSchemes(), "lnbc1example")
    }

    func testRemovingLightningSchemesLeavesPlainBech32Untouched() {
        let bech32 = "lnurl1dp68gcpwngkehj8atm6dza6wgx4crmuemh0kuy3ery9mg6venc6umjj0k7jr"
        XCTAssertEqual(bech32.removingLightningSchemes(), bech32)
    }

    func testRemovingLightningSchemesTrimsWhitespace() {
        XCTAssertEqual("  lnurlw:lnurl1example  ".removingLightningSchemes(), "lnurl1example")
    }
}
