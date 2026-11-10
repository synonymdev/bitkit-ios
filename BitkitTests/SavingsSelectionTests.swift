@testable import Bitkit
import XCTest

final class SavingsSelectionTests: XCTestCase {
    private let channels = ["a", "b"]

    func testDefaultMovesEveryChannelAndSpark() {
        let selection = resolve(selected: nil, spark: true, sparkSats: 5000)

        XCTAssertEqual(selection, SavingsSelection(channelIds: ["a", "b"], withdrawsSpark: true))
    }

    func testSparkOnlyWithoutChannels() {
        let selection = SavingsSelection.resolve(readyChannelIds: [], selectedChannelIds: nil, isSparkSelected: true, sparkSats: 5000)

        XCTAssertEqual(selection, SavingsSelection(channelIds: [], withdrawsSpark: true))
        XCTAssertFalse(selection.isEmpty)
    }

    func testChannelsOnlyWithoutSparkBalance() {
        let selection = resolve(selected: nil, spark: true, sparkSats: 0)

        XCTAssertEqual(selection, SavingsSelection(channelIds: ["a", "b"], withdrawsSpark: false))
    }

    func testDeselectedSparkIsNotWithdrawn() {
        let selection = resolve(selected: ["a", "b"], spark: false, sparkSats: 5000)

        XCTAssertEqual(selection, SavingsSelection(channelIds: ["a", "b"], withdrawsSpark: false))
    }

    func testSparkAloneClosesNoChannel() {
        let selection = resolve(selected: [], spark: true, sparkSats: 5000)

        XCTAssertEqual(selection, SavingsSelection(channelIds: [], withdrawsSpark: true))
    }

    func testPartialChannelSelection() {
        let selection = resolve(selected: ["b"], spark: true, sparkSats: 5000)

        XCTAssertEqual(selection, SavingsSelection(channelIds: ["b"], withdrawsSpark: true))
    }

    func testSelectedChannelThatIsNoLongerReadyIsDropped() {
        let selection = resolve(selected: ["b", "gone"], spark: false, sparkSats: 5000)

        XCTAssertEqual(selection.channelIds, ["b"])
    }

    func testNothingSelectedIsEmpty() {
        XCTAssertTrue(resolve(selected: [], spark: false, sparkSats: 5000).isEmpty)
    }

    @MainActor
    func testCommittingResetsThePickToAll() {
        let transfer = TransferViewModel()
        transfer.selectedChannelIds = ["a"]
        transfer.isSparkSelected = false

        transfer.onTransferToSavingsConfirm(channels: [], withdrawsSpark: false)

        XCTAssertNil(transfer.selectedChannelIds)
        XCTAssertTrue(transfer.isSparkSelected)
    }

    @MainActor
    func testEnteringTheFlowDropsAPickLeftFromAnAbandonedVisit() {
        let transfer = TransferViewModel()
        transfer.selectedChannelIds = ["closed-since"]
        transfer.isSparkSelected = false

        transfer.beginSavingsTransfer()

        XCTAssertNil(transfer.selectedChannelIds)
        XCTAssertTrue(transfer.isSparkSelected)
    }

    private func resolve(selected: Set<String>?, spark: Bool, sparkSats: UInt64) -> SavingsSelection {
        SavingsSelection.resolve(readyChannelIds: channels, selectedChannelIds: selected, isSparkSelected: spark, sparkSats: sparkSats)
    }
}
