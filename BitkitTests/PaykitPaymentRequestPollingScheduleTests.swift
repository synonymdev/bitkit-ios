@testable import Bitkit
import XCTest

final class PaykitPaymentRequestPollingScheduleTests: XCTestCase {
    func testInboxKeepsTenSecondChecksAndSlowerMaintenance() {
        var schedule = PaykitPaymentRequestPollingSchedule()
        var elapsed: Duration = .zero
        var maintenanceTimes: [Duration] = []

        for _ in 0 ..< 21 {
            XCTAssertEqual(schedule.nextDelay, .seconds(10))
            elapsed += schedule.nextDelay
            switch schedule.takeRound(isConnected: true) {
            case .skip:
                XCTFail("Connected polling rounds should refresh the inbox")
            case .refreshInbox:
                break
            case .refreshInboxAndMaintenance:
                maintenanceTimes.append(elapsed)
            }
        }

        XCTAssertEqual(maintenanceTimes, [.seconds(30), .seconds(90), .seconds(210)])
    }

    func testOfflineRoundSkipsWorkWithoutAdvancingMaintenance() {
        var schedule = PaykitPaymentRequestPollingSchedule()

        XCTAssertEqual(schedule.takeRound(isConnected: false), .skip)
        XCTAssertEqual(schedule.nextDelay, .seconds(10))
        XCTAssertEqual(schedule.takeRound(isConnected: true), .refreshInbox)
        XCTAssertEqual(schedule.takeRound(isConnected: true), .refreshInbox)
        XCTAssertEqual(schedule.takeRound(isConnected: true), .refreshInboxAndMaintenance)
    }
}
