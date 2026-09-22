@testable import Bitkit
import XCTest

final class PaykitPaymentRequestPollingScheduleTests: XCTestCase {
    func testSuccessfulIdleInboxKeepsTenSecondChecksAndSlowerMaintenance() {
        var schedule = PaykitPaymentRequestPollingSchedule()
        var elapsed: Duration = .zero
        var maintenanceTimes: [Duration] = []

        for _ in 0 ..< 21 {
            XCTAssertEqual(schedule.nextDelay, .seconds(10))
            elapsed += schedule.nextDelay
            if schedule.takeMaintenanceIfDue() { maintenanceTimes.append(elapsed) }
            schedule.recordRefresh(succeeded: true)
        }

        XCTAssertEqual(maintenanceTimes, [.seconds(30), .seconds(90), .seconds(210)])
    }

    func testFailuresBackOffAndSuccessResumesTenSecondChecks() {
        var schedule = PaykitPaymentRequestPollingSchedule()

        for delay in [10, 30, 60, 120, 120] {
            XCTAssertEqual(schedule.nextDelay, .seconds(delay))
            schedule.recordRefresh(succeeded: false)
        }

        schedule.recordRefresh(succeeded: true)
        XCTAssertEqual(schedule.nextDelay, .seconds(10))
    }
}
