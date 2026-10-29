@testable import Bitkit
import Combine
import LDKNode
import XCTest

@MainActor
final class ConnectionNavigationTests: XCTestCase {
    func testSuccessfulCloseReturnsToConnectionsInOneUpdate() {
        let channel = ChannelDetails.mock()
        let navigation = NavigationViewModel()

        for prefix: [Route] in [[.connections], [.activityList], []] {
            let expectedPath = prefix + [.connectionDetail(channelId: channel.channelIdString), .closeConnection(channel: channel)]
            navigation.path = expectedPath
            var updates: [[Route]] = []
            let subscription = navigation.$path.dropFirst().sink { updates.append($0) }

            navigation.returnToConnectionsAfterClosing(channelId: channel.channelIdString, from: expectedPath)

            let destination = prefix.last == .connections ? prefix : prefix + [.connections]
            XCTAssertEqual(navigation.path, destination)
            XCTAssertEqual(updates, [destination])
            subscription.cancel()
        }
    }

    func testCloseCompletionPreservesChangedOrUnrelatedNavigation() {
        let channel = ChannelDetails.mock()
        let original: [Route] = [.connections, .connectionDetail(channelId: channel.channelIdString), .closeConnection(channel: channel)]
        let mismatchedDetail: [Route] = [.connections, .connectionDetail(channelId: "another-channel"), .closeConnection(channel: channel)]
        let navigation = NavigationViewModel()

        for (path, expectedPath, channelId) in [
            (original + [.activityList], original, channel.channelIdString),
            (original, original, "another-channel"),
            (mismatchedDetail, mismatchedDetail, channel.channelIdString),
        ] {
            navigation.path = path
            navigation.returnToConnectionsAfterClosing(channelId: channelId, from: expectedPath)
            XCTAssertEqual(navigation.path, path)
        }
    }
}
