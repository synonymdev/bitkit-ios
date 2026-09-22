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
            if schedule.takeMaintenanceIfDue() { maintenanceTimes.append(elapsed) }
        }

        XCTAssertEqual(maintenanceTimes, [.seconds(30), .seconds(90), .seconds(210)])
    }
}
