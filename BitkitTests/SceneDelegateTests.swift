@testable import Bitkit
import XCTest

final class SceneDelegateTests: XCTestCase {
    func testForwardsDeepLinksToSwiftUIRetentionPath() throws {
        let delegate = SceneDelegate()
        let url = try XCTUnwrap(URL(string: "bitkit://pubky-auth/setup?caps=example"))
        _ = DeepLinkRouter.shared.consume()
        let forwarded = expectation(description: "deep link forwarded")
        let observer = NotificationCenter.default.addObserver(
            forName: .deepLinkReceived,
            object: nil,
            queue: nil
        ) { notification in
            XCTAssertEqual(notification.object as? URL, url)
            forwarded.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        delegate.forwardDeepLink(url)

        wait(for: [forwarded], timeout: 1)
        XCTAssertEqual(DeepLinkRouter.shared.consume(), url)
    }
}
