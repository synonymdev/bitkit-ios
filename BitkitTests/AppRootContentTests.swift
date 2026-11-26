@testable import Bitkit
import XCTest

final class AppRootContentTests: XCTestCase {
    func testWipeGateWinsOverEveryOtherRootState() {
        for flags in 0 ..< 32 {
            let content = AppRootContent.resolve(
                isWipeGateUp: true,
                isTrezorEmulatorTesting: flags & 1 != 0,
                isShowingMigrationLoading: flags & 2 != 0,
                isRecoveryShown: flags & 4 != 0,
                hasCriticalUpdate: flags & 8 != 0,
                isProfileRecoveryBlocking: flags & 16 != 0
            )
            XCTAssertEqual(content, .wipeGate, "flags: \(flags)")
        }
    }

    func testWithoutTheGateTheRootKeepsItsOrder() {
        func resolve(trezor: Bool = false, migration: Bool = false, recovery: Bool = false, update: Bool = false,
                     profile: Bool = false) -> AppRootContent
        {
            AppRootContent.resolve(
                isWipeGateUp: false,
                isTrezorEmulatorTesting: trezor,
                isShowingMigrationLoading: migration,
                isRecoveryShown: recovery,
                hasCriticalUpdate: update,
                isProfileRecoveryBlocking: profile
            )
        }

        XCTAssertEqual(resolve(trezor: true, migration: true, recovery: true, update: true), .trezorEmulatorTest)
        XCTAssertEqual(resolve(migration: true, recovery: true, update: true), .migrationLoading)
        XCTAssertEqual(resolve(recovery: true, update: true), .recovery)
        XCTAssertEqual(resolve(update: true), .criticalUpdate)
        XCTAssertEqual(resolve(profile: true), .profileRecovery)
        XCTAssertEqual(resolve(migration: true, profile: true), .profileRecovery)
        XCTAssertEqual(resolve(update: true, profile: true), .criticalUpdate)
        XCTAssertEqual(resolve(), .wallet)
    }
}
