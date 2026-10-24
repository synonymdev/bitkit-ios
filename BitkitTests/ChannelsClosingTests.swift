@testable import Bitkit
import XCTest

final class ChannelsClosingTests: XCTestCase {
    func testCloseDateUsesMediumDateStyle() {
        XCTAssertEqual(ChannelsClosing.formattedCloseDate(locale: Locale(identifier: "en")), "Dec 15, 2026")
        XCTAssertEqual(ChannelsClosing.formattedCloseDate(locale: Locale(identifier: "de")), "15.12.2026")
    }
}
