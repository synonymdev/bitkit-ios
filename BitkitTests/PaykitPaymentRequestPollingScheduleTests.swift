@testable import Bitkit
import XCTest

final class PaykitPaymentRequestPollingScheduleTests: XCTestCase {
    func testInboxKeepsTenSecondChecksAndSlowerMaintenance() {
        let start = ContinuousClock.now
        var schedule = PaykitPaymentRequestPollingSchedule(now: start)
        var elapsed: Duration = .zero
        var maintenanceTimes: [Duration] = []

        for _ in 0 ..< 21 {
            XCTAssertEqual(schedule.nextDelay, .seconds(10))
            elapsed += schedule.nextDelay
            switch schedule.takeRound(isConnected: true, now: start.advanced(by: elapsed)) {
            case .skip:
                XCTFail("Connected polling rounds should refresh the inbox")
            case .refreshInbox:
                break
            case .refreshInboxAndMaintenance:
                maintenanceTimes.append(elapsed)
            }
        }

        XCTAssertEqual(maintenanceTimes, [.seconds(30), .seconds(90), .seconds(150), .seconds(210)])
    }

    func testOfflineRoundSkipsWorkAndReconnectRunsOverdueMaintenance() {
        let start = ContinuousClock.now
        var schedule = PaykitPaymentRequestPollingSchedule(now: start)

        XCTAssertEqual(schedule.takeRound(isConnected: false, now: start.advanced(by: .seconds(90))), .skip)
        XCTAssertEqual(schedule.nextDelay, .seconds(10))
        XCTAssertEqual(schedule.takeRound(isConnected: true, now: start.advanced(by: .seconds(100))), .refreshInboxAndMaintenance)
        XCTAssertEqual(schedule.takeRound(isConnected: true, now: start.advanced(by: .seconds(110))), .refreshInbox)
    }

    func testSlowRefreshCountsTowardNextMaintenanceDeadline() {
        let start = ContinuousClock.now
        var schedule = PaykitPaymentRequestPollingSchedule(now: start)

        XCTAssertEqual(schedule.takeRound(isConnected: true, now: start.advanced(by: .seconds(30))), .refreshInboxAndMaintenance)
        XCTAssertEqual(schedule.takeRound(isConnected: true, now: start.advanced(by: .seconds(80))), .refreshInbox)
        XCTAssertEqual(schedule.takeRound(isConnected: true, now: start.advanced(by: .seconds(100))), .refreshInboxAndMaintenance)
    }
}
