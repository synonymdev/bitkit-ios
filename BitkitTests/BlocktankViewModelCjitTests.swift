@testable import Bitkit
import BitkitCore
import XCTest

final class BlocktankViewModelCjitTests: XCTestCase {
    func testWrappedNodeCapacityErrorNormalizesToDistinctError() {
        let wrappedError = AppError(
            message: AppError.genericMessage,
            debugMessage: "Failed to create CJIT entry: Node capacity is above our capacity limit"
        )

        let normalizedError = BlocktankViewModel.normalizedCreateCjitError(wrappedError)

        XCTAssertEqual(String(describing: normalizedError), String(describing: CustomServiceError.cjitNodeCapacityExceeded))
        XCTAssertFalse(normalizedError.isChannelSizeExceedsMaximum)
    }

    func testMaxChannelSizeErrorDoesNotNormalizeToNodeCapacity() {
        let wrappedError = AppError(
            message: AppError.genericMessage,
            debugMessage: "Failed to create CJIT entry: Channel size is too big. Checkout maxChannelSizeSat in the getInfo call."
        )

        let normalizedError = BlocktankViewModel.normalizedCreateCjitError(wrappedError)

        XCTAssertEqual(String(describing: normalizedError), String(describing: CustomServiceError.channelSizeExceedsMaximum))
        XCTAssertFalse(normalizedError.isCjitNodeCapacityExceeded)
    }

    func testCjitEntryValidationRejectsFeeGreaterThanReceiveAmount() {
        let entry = IcJitEntry.mock(feeSat: 5001)

        XCTAssertThrowsError(
            try BlocktankViewModel.validateCjitEntry(entry, receiveAmountSats: 5000)
        ) { error in
            XCTAssertEqual(String(describing: error), String(describing: CustomServiceError.invalidCjitQuote))
        }
    }

    func testCjitEntryValidationRejectsUserBalanceAboveChannelSize() {
        let entry = IcJitEntry.mock(channelSizeSat: 3000, feeSat: 1000)

        XCTAssertThrowsError(
            try BlocktankViewModel.validateCjitEntry(entry, receiveAmountSats: 5000)
        ) { error in
            XCTAssertEqual(String(describing: error), String(describing: CustomServiceError.invalidCjitQuote))
        }
    }

    func testCjitEntryValidationAllowsValidQuote() {
        let entry = IcJitEntry.mock(channelSizeSat: 10000, feeSat: 1000)

        XCTAssertNoThrow(
            try BlocktankViewModel.validateCjitEntry(entry, receiveAmountSats: 5000)
        )
    }
}
