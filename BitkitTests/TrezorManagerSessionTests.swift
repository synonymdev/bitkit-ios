@testable import Bitkit
import XCTest

/// How a Trezor session makes way for another vendor: a foreground reconnect reads as active from the
/// moment it is started, and releasing the session or wiping the wallet cancels it before it runs.
@MainActor
final class TrezorManagerSessionTests: XCTestCase {
    func testAForegroundReconnectReadsAsActiveBeforeItFirstRuns() {
        let manager = TrezorManager()

        manager.startAutoReconnect()

        XCTAssertTrue(manager.isSessionActive)
    }

    func testReleasingCancelsAPendingForegroundReconnect() async {
        let manager = TrezorManager()
        manager.startAutoReconnect()

        await manager.releaseSession()

        XCTAssertFalse(manager.isSessionActive)
    }

    func testWipeCancelsAPendingForegroundReconnectAndDropsTheLoadedDevices() async {
        let manager = TrezorManager()
        manager.knownDevices = [makeTrezor()]
        manager.startAutoReconnect()

        await manager.resetForWipe()

        XCTAssertFalse(manager.isSessionActive)
        XCTAssertTrue(manager.knownDevices.isEmpty)
    }

    private func makeTrezor() -> HwKnownDevice {
        HwKnownDevice(
            id: "trezor-dev",
            name: "Trezor",
            path: "ble:trezor",
            transportType: "bluetooth",
            model: "Safe 7",
            lastConnectedAt: Date(timeIntervalSince1970: 0),
            xpubs: ["nativeSegwit": "zTrezor"],
            walletId: "trezor:standard"
        )
    }
}
