@testable import Bitkit
import Paykit
import XCTest

final class PaykitNewerStateTests: XCTestCase {
    func testSharedStateFromANewerPaykitAsksForAnUpdate() {
        let newerVersion = Bitkit.AppError(
            error: PaykitError.Storage(code: "storage_error", context: "unsupported SDK state blob version 6, expected 4")
        )
        let trailingBytes = PaykitError.Storage(code: "storage_error", context: "SDK state blob contains trailing bytes")

        XCTAssertEqual(newerVersion.profileErrorDescription, t("profile__update_required"))
        XCTAssertTrue(trailingBytes.isPaykitStateFromNewerVersion())
    }

    func testOtherStorageFailuresKeepTheirDescription() {
        let corrupted = PaykitError.Storage(code: "storage_error", context: "SDK state blob version 2 contains trailing bytes")

        XCTAssertFalse(corrupted.isPaykitStateFromNewerVersion())
        XCTAssertEqual(corrupted.profileErrorDescription, corrupted.localizedDescription)
    }
}
