@testable import Bitkit
import XCTest

final class PaykitPaymentRequestPollingScheduleTests: XCTestCase {
    func testIdleInboxAndMaintenanceBackOffIndependently() {
        var schedule = PaykitPaymentRequestPollingSchedule()
        var elapsed: Duration = .zero
        var maintenanceTimes: [Duration] = []

        for delay in [5, 10, 15, 30, 30, 30, 30, 30, 30] {
            XCTAssertEqual(schedule.nextDelay, .seconds(delay))
            elapsed += schedule.nextDelay
            if schedule.takeMaintenanceIfDue() { maintenanceTimes.append(elapsed) }
            schedule.recordRefresh(requestsChanged: false)
        }

        XCTAssertEqual(maintenanceTimes, [.seconds(30), .seconds(90), .seconds(210)])
    }

    func testRequestChangesResetInboxWithoutResettingMaintenance() {
        var schedule = PaykitPaymentRequestPollingSchedule()
        var elapsed: Duration = .zero
        var maintenanceTimes: [Duration] = []

        for _ in 0 ..< 4 {
            elapsed += schedule.nextDelay
            if schedule.takeMaintenanceIfDue() { maintenanceTimes.append(elapsed) }
            schedule.recordRefresh(requestsChanged: elapsed == .seconds(60))
        }
        while elapsed < .seconds(210) {
            XCTAssertEqual(schedule.nextDelay, .seconds(5))
            elapsed += schedule.nextDelay
            if schedule.takeMaintenanceIfDue() { maintenanceTimes.append(elapsed) }
            schedule.recordRefresh(requestsChanged: true)
        }

        XCTAssertEqual(maintenanceTimes, [.seconds(30), .seconds(90), .seconds(210)])
    }
}
