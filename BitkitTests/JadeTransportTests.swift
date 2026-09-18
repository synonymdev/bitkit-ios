@testable import Bitkit
import BitkitCore
import Combine
import CoreBluetooth
import XCTest

final class JadeTransportTests: XCTestCase {
    private let path = "ble:2F8C7A10-4B3E-4D1A-9E6C-5A7B8C9D0E1F"
    private let staleBondText = "Bluetooth pairing is no longer valid: forget the Jade in the iOS Bluetooth settings and pair it again."

    private var driver: FakeBLEDriver!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        driver = FakeBLEDriver()
    }

    override func tearDown() {
        cancellables.removeAll()
        driver = nil
        super.tearDown()
    }

    private func makeTransport(isTrezorBridgeEnabled: Bool = false) -> JadeTransport {
        JadeTransport(driver: driver, isTrezorBridgeEnabled: { isTrezorBridgeEnabled })
    }

    // MARK: - Chunk size

    func testChunkSizeClampsMaximumWriteLength() {
        XCTAssertEqual(JadeBLEManager.chunkSize(maximumWriteLength: -1), 1)
        XCTAssertEqual(JadeBLEManager.chunkSize(maximumWriteLength: 0), 1)
        XCTAssertEqual(JadeBLEManager.chunkSize(maximumWriteLength: 20), 20)
        XCTAssertEqual(JadeBLEManager.chunkSize(maximumWriteLength: 244), 244)
        XCTAssertEqual(JadeBLEManager.chunkSize(maximumWriteLength: 509), 509)
        XCTAssertEqual(JadeBLEManager.chunkSize(maximumWriteLength: 512), 509)
    }

    func testChunkSizeDefaultsTo20WhenNotOpen() {
        let transport = JadeTransport(driver: JadeBLEManager(), isTrezorBridgeEnabled: { false })

        XCTAssertEqual(transport.getChunkSize(path: path), 20)
    }

    func testChunkSizeComesFromTheDriver() {
        driver.stubs.chunkSizes = [path: 182]

        XCTAssertEqual(makeTransport().getChunkSize(path: path), 182)
    }

    // MARK: - Unopened paths

    func testOperationsOnUnopenedDeviceReportNotConnected() {
        let transport = JadeTransport(driver: JadeBLEManager(), isTrezorBridgeEnabled: { false })

        let read = transport.readChunk(path: path, timeoutMs: 50)
        XCTAssertFalse(read.success)
        XCTAssertTrue(read.data.isEmpty)
        XCTAssertEqual(read.errorCode, .notConnected)
        XCTAssertEqual(read.error, "Jade is not connected.")

        let write = transport.writeChunk(path: path, data: Data([0x01]))
        XCTAssertFalse(write.success)
        XCTAssertEqual(write.errorCode, .notConnected)

        XCTAssertTrue(transport.closeDevice(path: path).success)
    }

    func testOpeningAnInvalidPathFailsWithoutStartingBluetooth() {
        let manager = JadeBLEManager()
        let transport = JadeTransport(driver: manager, isTrezorBridgeEnabled: { false })

        let result = transport.openDevice(path: "usb:jade")

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, "Invalid Jade Bluetooth path: usb:jade")
        XCTAssertNil(result.errorCode)
        XCTAssertFalse(manager.hasCentral)
    }

    func testCentralIsOnlyCreatedByScanOrOpen() {
        let manager = JadeBLEManager()
        let transport = JadeTransport(driver: manager, isTrezorBridgeEnabled: { false })

        manager.setPairedPaths([path])
        manager.releaseAllImmediately()
        manager.closeAll()
        _ = manager.chunkSize(path: path)
        manager.externalDisconnects.sink { _ in }.store(in: &cancellables)
        manager.bluetoothPoweredOn.sink { _ in }.store(in: &cancellables)
        _ = transport.readChunk(path: path, timeoutMs: 10)
        _ = transport.writeChunk(path: path, data: Data([0x01]))
        _ = transport.closeDevice(path: path)
        transport.releaseAllImmediately()
        transport.setPairedPaths([])

        XCTAssertFalse(manager.hasCentral)
    }

    // MARK: - Reads

    func testReadTimeoutIsEmptySuccess() {
        driver.stubs.readResult = .success(Data())

        let result = makeTransport().readChunk(path: path, timeoutMs: 250)

        XCTAssertEqual(result, JadeTransportReadResult(success: true, data: Data(), error: "", errorCode: nil))
        XCTAssertEqual(driver.calls.readTimeouts, [0.25])
    }

    func testReadReturnsArrivedBytes() {
        driver.stubs.readResult = .success(Data([0xA1, 0xB2, 0xC3]))

        let result = makeTransport().readChunk(path: path, timeoutMs: 100)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.data, Data([0xA1, 0xB2, 0xC3]))
        XCTAssertNil(result.errorCode)
    }

    func testReadAfterLinkDropReportsDisconnected() {
        driver.stubs.readResult = .failure(.disconnected)

        let result = makeTransport().readChunk(path: path, timeoutMs: 250)

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.data.isEmpty)
        XCTAssertEqual(result.errorCode, .disconnected)
        XCTAssertEqual(result.error, "Your Jade disconnected.")
    }

    // MARK: - Writes

    func testWriteSendsTheChunkToTheDriver() {
        let result = makeTransport().writeChunk(path: path, data: Data([0x01, 0x02]))

        XCTAssertEqual(result, JadeTransportResult(success: true, error: "", errorCode: nil))
        XCTAssertEqual(driver.calls.writes.map(\.path), [path])
        XCTAssertEqual(driver.calls.writes.map(\.data), [Data([0x01, 0x02])])
    }

    func testWriteTimeoutReportsTimeoutCode() {
        driver.stubs.writeError = .writeTimeout

        let result = makeTransport().writeChunk(path: path, data: Data([0x01]))

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorCode, .timeout)
        XCTAssertEqual(result.error, "Timed out sending data to your Jade.")
    }

    func testStaleBondHasNoErrorCodeAndVerbatimText() {
        driver.stubs.writeError = .staleBond

        let result = makeTransport().writeChunk(path: path, data: Data([0x01]))

        XCTAssertFalse(result.success)
        XCTAssertNil(result.errorCode)
        XCTAssertEqual(result.error, staleBondText)
        XCTAssertNil(JadeBLEError.staleBond.transportErrorCode)
        XCTAssertEqual(JadeBLEError.staleBond.localizedDescription, staleBondText)
    }

    func testErrorCodesFollowTheFailure() {
        XCTAssertEqual(JadeTransport.errorCode(for: JadeBLEError.notOpen), .notConnected)
        XCTAssertEqual(JadeTransport.errorCode(for: JadeBLEError.deviceNotFound), .notConnected)
        XCTAssertEqual(JadeTransport.errorCode(for: JadeBLEError.connectTimeout), .timeout)
        XCTAssertEqual(JadeTransport.errorCode(for: JadeBLEError.closed), .disconnected)
        XCTAssertNil(JadeTransport.errorCode(for: JadeBLEError.pairingNotConfirmed))
        XCTAssertNil(JadeTransport.errorCode(for: JadeBLEError.writeFailed("busy")))
        XCTAssertNil(JadeTransport.errorCode(for: CancellationError()))
    }

    // MARK: - Opening and closing

    func testOpenReportsTheFailureText() {
        driver.stubs.openError = .pairingNotConfirmed

        let result = makeTransport().openDevice(path: path)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, "Bluetooth pairing with your Jade was not confirmed. Try again and accept the pairing request.")
        XCTAssertEqual(driver.calls.openedPaths, [path])
    }

    func testOpenSucceedsWhenTheDriverOpens() {
        XCTAssertEqual(makeTransport().openDevice(path: path), JadeTransportResult(success: true, error: "", errorCode: nil))
    }

    func testCloseAlwaysSucceeds() {
        let transport = makeTransport()

        XCTAssertTrue(transport.closeDevice(path: path).success)
        XCTAssertTrue(transport.closeDevice(path: path).success)
        XCTAssertEqual(driver.calls.closedPaths, [path, path])
    }

    @MainActor
    func testDisconnectDeviceClosesOffTheMainThread() async {
        let transport = makeTransport()

        await transport.disconnectDevice(path: path)
        await transport.closeAllConnections()

        XCTAssertEqual(driver.calls.closedPaths, [path])
        XCTAssertEqual(driver.calls.closedOnMainThread, [false])
        XCTAssertEqual(driver.calls.closeAllCount, 1)
    }

    func testControlCallsReachTheDriver() {
        let transport = makeTransport()

        transport.setPairedPaths([path])
        transport.releaseAllImmediately()

        XCTAssertEqual(driver.calls.pairedPaths, [path])
        XCTAssertEqual(driver.calls.releaseAllCount, 1)
    }

    func testPublishersForwardDriverEvents() {
        let transport = makeTransport()
        var disconnectedPaths: [String] = []
        var poweredOnCount = 0
        transport.externalDisconnects.sink { disconnectedPaths.append($0) }.store(in: &cancellables)
        transport.bluetoothPoweredOn.sink { poweredOnCount += 1 }.store(in: &cancellables)

        driver.externalDisconnectSubject.send(path)
        driver.poweredOnSubject.send(())

        XCTAssertEqual(disconnectedPaths, [path])
        XCTAssertEqual(poweredOnCount, 1)
    }

    // MARK: - Scanning

    func testScanDurationIsClamped() {
        XCTAssertEqual(JadeTransport.scanDuration(timeoutMs: 0), 0.5)
        XCTAssertEqual(JadeTransport.scanDuration(timeoutMs: 499), 0.5)
        XCTAssertEqual(JadeTransport.scanDuration(timeoutMs: 3000), 3)
        XCTAssertEqual(JadeTransport.scanDuration(timeoutMs: 15000), 15)
        XCTAssertEqual(JadeTransport.scanDuration(timeoutMs: 60000), 15)
    }

    func testScanMapsDiscoveriesToBluetoothDevices() {
        driver.stubs.discoveries = [
            JadeBLEDiscovery(path: path, name: "Jade 8F6B64"),
            JadeBLEDiscovery(path: "ble:9A1B2C3D-4E5F-4061-8293-A4B5C6D7E8F9", name: "Jade"),
        ]

        let devices = makeTransport().scanDevices(timeoutMs: 3000)

        XCTAssertEqual(devices, [
            JadeNativeDevice(path: path, transport: .bluetooth, name: "Jade 8F6B64", serialNumber: nil),
            JadeNativeDevice(path: "ble:9A1B2C3D-4E5F-4061-8293-A4B5C6D7E8F9", transport: .bluetooth, name: "Jade", serialNumber: nil),
        ])
        XCTAssertEqual(driver.calls.scanDurations, [3])
    }

    func testScanIsSkippedWhileTrezorBridgeIsEnabled() {
        driver.stubs.discoveries = [JadeBLEDiscovery(path: path, name: "Jade 8F6B64")]

        let devices = makeTransport(isTrezorBridgeEnabled: true).scanDevices(timeoutMs: 3000)

        XCTAssertTrue(devices.isEmpty)
        XCTAssertTrue(driver.calls.scanDurations.isEmpty)
    }

    func testOnlyJadeNamesPassTheScanFilter() {
        XCTAssertTrue(JadeBLEManager.isJadeName(nil))
        XCTAssertTrue(JadeBLEManager.isJadeName("Jade"))
        XCTAssertTrue(JadeBLEManager.isJadeName("Jade 8F6B64"))
        XCTAssertTrue(JadeBLEManager.isJadeName("jade plus"))
        XCTAssertFalse(JadeBLEManager.isJadeName("Nordic UART"))
        XCTAssertFalse(JadeBLEManager.isJadeName("My Jade"))
        XCTAssertFalse(JadeBLEManager.isJadeName(""))
    }

    // MARK: - Error mapping

    func testCoreBluetoothPairingErrorsMapToPairingAdvice() {
        let peerRemoved = NSError(domain: CBErrorDomain, code: CBError.Code.peerRemovedPairingInformation.rawValue)
        let encryptionTimedOut = NSError(domain: CBErrorDomain, code: CBError.Code.encryptionTimedOut.rawValue)
        let insufficientEncryption = NSError(domain: CBATTErrorDomain, code: CBATTError.Code.insufficientEncryption.rawValue)
        let insufficientAuthentication = NSError(domain: CBATTErrorDomain, code: CBATTError.Code.insufficientAuthentication.rawValue)
        let connectionTimeout = NSError(domain: CBErrorDomain, code: CBError.Code.connectionTimeout.rawValue)

        XCTAssertEqual(JadeBLEManager.pairingError(for: peerRemoved, isPaired: false), .staleBond)
        XCTAssertEqual(JadeBLEManager.pairingError(for: encryptionTimedOut, isPaired: true), .pairingNotConfirmed)
        XCTAssertEqual(JadeBLEManager.pairingError(for: insufficientEncryption, isPaired: true), .staleBond)
        XCTAssertEqual(JadeBLEManager.pairingError(for: insufficientEncryption, isPaired: false), .pairingNotConfirmed)
        XCTAssertEqual(JadeBLEManager.pairingError(for: insufficientAuthentication, isPaired: true), .staleBond)
        XCTAssertEqual(JadeBLEManager.pairingError(for: insufficientAuthentication, isPaired: false), .pairingNotConfirmed)
        XCTAssertNil(JadeBLEManager.pairingError(for: connectionTimeout, isPaired: true))
        XCTAssertNil(JadeBLEManager.pairingError(for: nil, isPaired: true))
    }

    func testFailureDetailsReadAsOneSentence() {
        XCTAssertEqual(
            JadeBLEError.writeFailed("The operation was cancelled.").localizedDescription,
            "Sending data to your Jade failed (The operation was cancelled)."
        )
        XCTAssertEqual(JadeBLEError.connectFailed("  ").localizedDescription, "Could not connect to your Jade over Bluetooth (unknown error).")
    }

    // MARK: - Paths

    func testDevicePathRoundTrip() throws {
        let identifier = try XCTUnwrap(UUID(uuidString: "2F8C7A10-4B3E-4D1A-9E6C-5A7B8C9D0E1F"))

        XCTAssertEqual(HwDevicePath.ble(identifier), path)
        XCTAssertTrue(HwDevicePath.isBle(path))
        XCTAssertEqual(HwDevicePath.bleIdentifier(path), identifier)
        XCTAssertFalse(HwDevicePath.isBle("usb:jade"))
        XCTAssertNil(HwDevicePath.bleIdentifier("usb:jade"))
        XCTAssertNil(HwDevicePath.bleIdentifier("ble:not-a-uuid"))
    }
}
