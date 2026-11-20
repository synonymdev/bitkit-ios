@testable import Bitkit
import SwiftUI
import XCTest

@MainActor
final class OfflineSheetOverlayTests: XCTestCase {
    private final class Box {
        var isCovered: Bool?
    }

    private struct Probe: View {
        @Environment(\.isCoveredByOfflineSheet) private var isCovered
        let box: Box

        var body: some View {
            box.isCovered = isCovered
            return Color.clear.frame(width: 10, height: 10)
        }
    }

    private func isCovered(forceShow: Bool, isEnabled: Bool) -> Bool? {
        let box = Box()
        let view = Probe(box: box)
            .offlineSheetOverlay(title: "Send", forceShow: forceShow, isEnabled: isEnabled)
            .environmentObject(NetworkMonitor())
        _ = UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 320, height: 640))
        return box.isCovered
    }

    func testCoveredContentKnowsItIsCovered() {
        XCTAssertEqual(isCovered(forceShow: true, isEnabled: true), true)
        XCTAssertEqual(isCovered(forceShow: true, isEnabled: false), false)
    }
}
