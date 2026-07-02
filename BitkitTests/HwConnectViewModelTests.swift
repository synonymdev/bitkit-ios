@testable import Bitkit
import BitkitCore
import XCTest

@MainActor
final class HwConnectViewModelTests: XCTestCase {
    private var service: FakeHwConnectService!
    private var sut: HwConnectViewModel!

    override func setUp() {
        super.setUp()
        service = FakeHwConnectService()
        sut = HwConnectViewModel(service: service)
    }

    override func tearDown() {
        sut.reset()
        sut = nil
        service = nil
        super.tearDown()
    }

    // MARK: - Searching

    func testOnIntroContinueSearchesThenAdvancesToFoundWithFirstDevice() async {
        service.nearbyDevices = [makeDevice(id: "dev1", model: "Safe 3")]

        sut.onIntroContinue()

        await waitUntil { self.sut.phase == .found }
        XCTAssertEqual(sut.phase, .found)
        XCTAssertEqual(sut.foundDevice?.id, "dev1")
        XCTAssertEqual(sut.foundDeviceModel, "Trezor Safe 3")
        XCTAssertNil(sut.errorMessage)
    }

    func testOnIntroContinueSurfacesSearchFailureWhileSearching() async {
        service.scanError = TestError.stub

        sut.onIntroContinue()

        await waitUntil { self.sut.errorMessage != nil }
        XCTAssertEqual(sut.phase, .searching)
        XCTAssertEqual(sut.errorMessage, t("hardware__search_error"))
    }

    // MARK: - Connect

    func testOnConnectConnectsFoundDeviceAndAdvancesToPaired() async {
        await givenDeviceFound()
        service.connectResult = .success(HwConnectResult(deviceId: "dev1", name: "Trezor Safe 3"))

        sut.onConnect()

        await waitUntil { self.sut.phase == .paired }
        XCTAssertEqual(service.connectedDeviceIds, ["dev1"])
        XCTAssertEqual(sut.pairedDeviceId, "dev1")
        XCTAssertEqual(sut.deviceName, "Trezor Safe 3")
        XCTAssertEqual(sut.labelInput, "Trezor Safe 3")
        XCTAssertFalse(sut.isConnecting)
    }

    func testOnConnectSurfacesFailureAndReturnsToFound() async {
        await givenDeviceFound()
        service.connectResult = .failure(TestError.stub)

        sut.onConnect()

        await waitUntil { self.sut.errorMessage != nil }
        XCTAssertEqual(sut.phase, .found)
        XCTAssertFalse(sut.isConnecting)
        XCTAssertEqual(sut.errorMessage, t("hardware__connect_error"))
        XCTAssertEqual(sut.foundDevice?.id, "dev1")
    }

    // MARK: - Pairing code

    func testPairingCodeRequestSurfacesInlinePairCodeStepWhileConnecting() async {
        await givenDeviceFound()
        service.connectResult = .success(HwConnectResult(deviceId: "dev1", name: "Trezor Safe 3"))

        // onConnect flips isConnecting synchronously; the connect Task is queued but not yet run,
        // so the pairing-code request lands mid-connect exactly as it would on device.
        sut.onConnect()
        XCTAssertTrue(sut.isConnecting)
        sut.onPairingCodeRequested()

        XCTAssertEqual(sut.phase, .pairCode)
    }

    func testPairingCodeRequestIgnoredWhenNotConnecting() {
        sut.onPairingCodeRequested()
        XCTAssertEqual(sut.phase, .intro)
    }

    // MARK: - Paired

    func testConnectedWalletUpdatesBalanceOnPairedStep() async {
        await givenDevicePaired()

        sut.onWalletsUpdated([makeWallet(id: "dev1", name: "Trezor Safe 3", balance: 10_562_411)])

        XCTAssertEqual(sut.balanceSats, 10_562_411)
        XCTAssertEqual(sut.deviceName, "Trezor Safe 3")
    }

    func testOnLabelChangeCapsTheLabelInput() {
        sut.onLabelChange(String(repeating: "a", count: 51))
        XCTAssertEqual(sut.labelInput, String(repeating: "a", count: 50))
    }

    func testOnFinishPersistsEditedLabelAndFinishes() async {
        await givenDevicePaired()
        sut.onLabelChange("My Cold Wallet")
        var finished = false
        sut.onFinished = { finished = true }

        sut.onFinish()

        XCTAssertEqual(service.setLabelCalls.count, 1)
        XCTAssertEqual(service.setLabelCalls.first?.id, "dev1")
        XCTAssertEqual(service.setLabelCalls.first?.label, "My Cold Wallet")
        XCTAssertTrue(finished)
    }

    // MARK: - Helpers

    private func givenDeviceFound() async {
        service.nearbyDevices = [makeDevice(id: "dev1", model: "Safe 3")]
        sut.onIntroContinue()
        await waitUntil { self.sut.phase == .found }
    }

    private func givenDevicePaired() async {
        await givenDeviceFound()
        service.connectResult = .success(HwConnectResult(deviceId: "dev1", name: "Trezor Safe 3"))
        sut.onConnect()
        await waitUntil { self.sut.phase == .paired }
    }

    private func makeDevice(id: String, model: String?) -> TrezorDeviceInfo {
        TrezorDeviceInfo(
            id: id,
            transportType: .bluetooth,
            name: nil,
            path: "ble:\(id)",
            label: nil,
            model: model,
            isBootloader: false
        )
    }

    private func makeWallet(id: String, name: String, balance: UInt64) -> HwWallet {
        HwWallet(id: id, walletId: "trezor:\(id)", name: name, model: nil, isConnected: true, balanceSats: balance)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private enum TestError: Error {
    case stub
}

@MainActor
private final class FakeHwConnectService: HwConnectServicing {
    var nearbyDevices: [TrezorDeviceInfo] = []
    var scanError: Error?
    var connectResult: Result<HwConnectResult, Error> = .failure(TestError.stub)

    private(set) var scanCount = 0
    private(set) var connectedDeviceIds: [String] = []
    private(set) var setLabelCalls: [(id: String, label: String)] = []
    private(set) var cancelPairingCount = 0

    func scanForUnpairedDevices() async throws -> [TrezorDeviceInfo] {
        scanCount += 1
        if let scanError { throw scanError }
        return nearbyDevices
    }

    func connect(to device: TrezorDeviceInfo) async throws -> HwConnectResult {
        connectedDeviceIds.append(device.id)
        return try connectResult.get()
    }

    func setDeviceLabel(id: String, label: String) {
        setLabelCalls.append((id, label))
    }

    func cancelPairingCode() {
        cancelPairingCount += 1
    }
}
