@testable import Bitkit
import Combine
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

    func testAWipeWithNoDeviceConnectedDropsAKeptPassphrase() async {
        let manager = TrezorManager()
        TrezorUiHandler.shared.setWalletMode(.passphraseHost, hostPassphrase: "hidden wallet")
        XCTAssertEqual(TrezorUiHandler.shared.currentSelection(), .hidden(passphrase: "hidden wallet"))

        await manager.resetForWipe()

        XCTAssertEqual(TrezorUiHandler.shared.currentSelection(), .standard)
        XCTAssertEqual(manager.walletMode, .standard)
    }

    func testWipeAnswersAPinRequestStillPending() async {
        let manager = TrezorManager()
        var pendingRequestId: Int?
        let subscription = TrezorUiHandler.shared.pinRequestIds.sink { pendingRequestId = $0 }
        defer { subscription.cancel() }
        let request = Task.detached { TrezorUiHandler.shared.onPinRequest() }
        await eventually("the request is pending") { pendingRequestId != nil }

        await manager.resetForWipe()

        let pin = await request.value
        XCTAssertEqual(pin, "")
    }

    func testPinRequestsAreShownAgainOnceAWipeHasDrained() async {
        let manager = TrezorManager()
        var pendingRequestId: Int?
        let subscription = TrezorUiHandler.shared.pinRequestIds.sink { pendingRequestId = $0 }
        defer { subscription.cancel() }
        await manager.resetForWipe()

        let request = Task.detached { TrezorUiHandler.shared.onPinRequest() }
        await eventually("the request is pending, not refused") { pendingRequestId != nil }
        if let pendingRequestId {
            TrezorUiHandler.shared.submitPin("1234", requestId: pendingRequestId)
        } else {
            TrezorUiHandler.shared.cancelPin(requestId: nil)
        }
        let pin = await request.value

        XCTAssertEqual(pin, "1234")
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
