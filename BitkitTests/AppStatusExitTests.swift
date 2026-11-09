@testable import Bitkit
import XCTest

final class AppStatusExitTests: XCTestCase {
    func testExitStepIsNilWithoutARunningExit() {
        XCTAssertNil(AppStatusHelper.exitStep(record: nil))
        XCTAssertNil(AppStatusHelper.exitStep(record: record(.done)))
        XCTAssertNil(AppStatusHelper.exitStep(record: record(.failed(reason: "reason"))))
    }

    func testExitStepMapsRunningAndFundingPhases() {
        XCTAssertEqual(AppStatusHelper.exitStep(record: record(.running)), .pending)
        XCTAssertEqual(AppStatusHelper.exitStep(record: record(.awaitingFunding(requiredSats: 1000))), .funding)
        XCTAssertEqual(AppStatusHelper.exitStep(record: record(.needsFunding(requiredSats: 1000))), .funding)
    }

    private func record(_ phase: SparkExitRecord.Phase) -> SparkExitRecord {
        SparkExitRecord(
            network: "regtest",
            createdAt: Date(),
            phase: phase,
            feeRateSatPerVbyte: 1,
            destination: "bcrt1qdestination",
            leafIds: ["leaf-1"],
            funding: [.init(index: 0, address: "bcrt1qfunding", pubkey: "02")],
            expectedSats: 1000
        )
    }
}
