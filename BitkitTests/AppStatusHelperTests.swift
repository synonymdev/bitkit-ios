@testable import Bitkit
import XCTest

final class AppStatusHelperTests: XCTestCase {
    func testSparkStatusIsNilWhenSparkIsUnsupported() {
        XCTAssertNil(AppStatusHelper.sparkStatus(isOnline: true, isSupported: false, isReady: true))
    }

    func testSparkStatusMapsToReadyPendingAndError() {
        XCTAssertEqual(AppStatusHelper.sparkStatus(isOnline: true, isSupported: true, isReady: true), .ready)
        XCTAssertEqual(AppStatusHelper.sparkStatus(isOnline: true, isSupported: true, isReady: false), .pending)
        XCTAssertEqual(AppStatusHelper.sparkStatus(isOnline: false, isSupported: true, isReady: true), .error)
    }

    func testChannelsStatusIsReadyThroughSparkWhenNoChannelIsUsable() {
        let status = AppStatusHelper.channelsStatus(isOnline: true, hasUsableChannels: false, hasChannels: true, isSparkReady: true)
        XCTAssertEqual(status, .ready)
        XCTAssertTrue(AppStatusHelper.isLightningViaSpark(isOnline: true, hasUsableChannels: false, isSparkReady: true))
    }

    func testChannelsStatusIsOpenWhenAChannelIsUsableBesideSpark() {
        let status = AppStatusHelper.channelsStatus(isOnline: true, hasUsableChannels: true, hasChannels: true, isSparkReady: true)
        XCTAssertEqual(status, .ready)
        XCTAssertFalse(AppStatusHelper.isLightningViaSpark(isOnline: true, hasUsableChannels: true, isSparkReady: true))
    }

    func testChannelsStatusIsErrorWhenNeitherAChannelNorSparkCanPay() {
        let status = AppStatusHelper.channelsStatus(isOnline: true, hasUsableChannels: false, hasChannels: false, isSparkReady: false)
        XCTAssertEqual(status, .error)
        XCTAssertFalse(AppStatusHelper.isLightningViaSpark(isOnline: true, hasUsableChannels: false, isSparkReady: false))
    }

    func testChannelsStatusIsErrorOfflineEvenWithSpark() {
        let status = AppStatusHelper.channelsStatus(isOnline: false, hasUsableChannels: false, hasChannels: false, isSparkReady: true)
        XCTAssertEqual(status, .error)
        XCTAssertFalse(AppStatusHelper.isLightningViaSpark(isOnline: false, hasUsableChannels: false, isSparkReady: true))
    }
}
