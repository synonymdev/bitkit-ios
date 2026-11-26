@testable import Bitkit
import XCTest

final class AppStatusHelperTests: XCTestCase {
    func testSparkStatusIsNilWhenSparkIsUnsupported() {
        XCTAssertNil(AppStatusHelper.sparkStatus(isOnline: true, isSupported: false, isReady: true, hasStartFailed: false))
    }

    func testSparkStatusMapsToReadyPendingAndError() {
        XCTAssertEqual(AppStatusHelper.sparkStatus(isOnline: true, isSupported: true, isReady: true, hasStartFailed: false), .ready)
        XCTAssertEqual(AppStatusHelper.sparkStatus(isOnline: true, isSupported: true, isReady: false, hasStartFailed: false), .pending)
        XCTAssertEqual(AppStatusHelper.sparkStatus(isOnline: false, isSupported: true, isReady: true, hasStartFailed: false), .error)
    }

    func testSparkStatusIsErrorWhenItsStartFailed() {
        XCTAssertEqual(AppStatusHelper.sparkStatus(isOnline: true, isSupported: true, isReady: false, hasStartFailed: true), .error)
    }

    func testChannelsStatusIsReadyThroughSparkWhenNoChannelIsUsable() {
        let status = AppStatusHelper.channelsStatus(isOnline: true, hasUsableChannels: false, hasChannels: true, isSparkUsable: true)
        XCTAssertEqual(status, .ready)
        XCTAssertTrue(AppStatusHelper.isLightningViaSpark(isOnline: true, hasUsableChannels: false, isSparkUsable: true))
    }

    func testChannelsStatusIsOpenWhenAChannelIsUsableBesideSpark() {
        let status = AppStatusHelper.channelsStatus(isOnline: true, hasUsableChannels: true, hasChannels: true, isSparkUsable: true)
        XCTAssertEqual(status, .ready)
        XCTAssertFalse(AppStatusHelper.isLightningViaSpark(isOnline: true, hasUsableChannels: true, isSparkUsable: true))
    }

    func testChannelsStatusIsErrorWhenNeitherAChannelNorSparkCanPay() {
        let status = AppStatusHelper.channelsStatus(isOnline: true, hasUsableChannels: false, hasChannels: false, isSparkUsable: false)
        XCTAssertEqual(status, .error)
        XCTAssertFalse(AppStatusHelper.isLightningViaSpark(isOnline: true, hasUsableChannels: false, isSparkUsable: false))
    }

    func testChannelsStatusIsErrorOfflineEvenWithSpark() {
        let status = AppStatusHelper.channelsStatus(isOnline: false, hasUsableChannels: false, hasChannels: false, isSparkUsable: true)
        XCTAssertEqual(status, .error)
        XCTAssertFalse(AppStatusHelper.isLightningViaSpark(isOnline: false, hasUsableChannels: false, isSparkUsable: true))
    }
}
