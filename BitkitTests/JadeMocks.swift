@testable import Bitkit
import BitkitCore
import Combine
import Foundation
import UIKit

/// A `JadeBLEDriving` that answers from stubs and records every call, for testing `JadeTransport`
/// without CoreBluetooth. Calls can arrive on any thread, so both are guarded by a lock.
final class FakeBLEDriver: JadeBLEDriving, @unchecked Sendable {
    struct Stubs {
        var discoveries: [JadeBLEDiscovery] = []
        var openError: JadeBLEError?
        var writeError: JadeBLEError?
        var readResult: Result<Data, JadeBLEError> = .success(Data())
        var chunkSizes: [String: UInt32] = [:]
    }

    struct Calls {
        var scanDurations: [TimeInterval] = []
        var openedPaths: [String] = []
        var closedPaths: [String] = []
        var closedOnMainThread: [Bool] = []
        var writes: [(path: String, data: Data)] = []
        var readTimeouts: [TimeInterval] = []
        var closeAllCount = 0
        var releaseAllCount = 0
        var pairedPaths: Set<String>?
    }

    let externalDisconnectSubject = PassthroughSubject<String, Never>()
    let poweredOnSubject = PassthroughSubject<Void, Never>()

    private let lock = NSLock()
    private var storedStubs = Stubs()
    private var recordedCalls = Calls()

    var stubs: Stubs {
        get { lock.withLock { storedStubs } }
        set { lock.withLock { storedStubs = newValue } }
    }

    var calls: Calls {
        lock.withLock { recordedCalls }
    }

    var externalDisconnects: AnyPublisher<String, Never> {
        externalDisconnectSubject.eraseToAnyPublisher()
    }

    var bluetoothPoweredOn: AnyPublisher<Void, Never> {
        poweredOnSubject.eraseToAnyPublisher()
    }

    func scan(duration: TimeInterval) -> [JadeBLEDiscovery] {
        lock.withLock {
            recordedCalls.scanDurations.append(duration)
            return storedStubs.discoveries
        }
    }

    func open(path: String) throws {
        let error: JadeBLEError? = lock.withLock {
            recordedCalls.openedPaths.append(path)
            return storedStubs.openError
        }
        if let error {
            throw error
        }
    }

    func close(path: String) {
        let isMainThread = Thread.isMainThread
        lock.withLock {
            recordedCalls.closedPaths.append(path)
            recordedCalls.closedOnMainThread.append(isMainThread)
        }
    }

    func write(path: String, data: Data) throws {
        let error: JadeBLEError? = lock.withLock {
            recordedCalls.writes.append((path, data))
            return storedStubs.writeError
        }
        if let error {
            throw error
        }
    }

    func read(path _: String, timeout: TimeInterval) throws -> Data {
        let result: Result<Data, JadeBLEError> = lock.withLock {
            recordedCalls.readTimeouts.append(timeout)
            return storedStubs.readResult
        }
        return try result.get()
    }

    func chunkSize(path: String) -> UInt32 {
        lock.withLock { storedStubs.chunkSizes[path] ?? JadeBLEManager.defaultChunkSize }
    }

    func closeAll() {
        lock.withLock { recordedCalls.closeAllCount += 1 }
    }

    func releaseAllImmediately() {
        lock.withLock { recordedCalls.releaseAllCount += 1 }
    }

    func setPairedPaths(_ paths: Set<String>) {
        lock.withLock { recordedCalls.pairedPaths = paths }
    }
}

// MARK: - Session manager fakes

/// One ordered record of the calls the Jade fakes receive, shared by the service and the transport so
/// a test can assert the order across both. Calls arrive on any thread, so it is guarded by a lock.
final class JadeCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var entries: [String] {
        lock.withLock { recorded }
    }

    func record(_ entry: String) {
        lock.withLock { recorded.append(entry) }
    }

    func count(_ entry: String) -> Int {
        entries.filter { $0 == entry }.count
    }

    func contains(_ entry: String) -> Bool {
        entries.contains(entry)
    }
}

/// Holds the calls that wait on it until a test opens it; once open it stays open.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                if isOpen {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func open() {
        let pending = lock.withLock {
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume() }
    }
}

enum JadeFixtures {
    static let efuseMac = "246F288F6B64"
    static let deviceId = "jade:bluetooth:\(efuseMac)"
    static let advertisedName = "Jade 8F6B64"
    static let walletId = "jade:wallet"
    static let blePath = "ble:6B7A9B16-C81C-4A4B-9B11-000000000001"
    static let stalePath = "ble:6B7A9B16-C81C-4A4B-9B11-000000000002"
    static let readvertisedPath = "ble:56C4BFB3-9E75-4A4B-9B11-000000000003"
    static let xpub = "zpubNS"

    static func version(_ state: JadeState, efuseMac: String? = efuseMac) -> JadeVersionInfo {
        JadeVersionInfo(
            jadeVersion: "1.0.41",
            jadeState: state,
            jadeNetworks: "ALL",
            jadeHasPin: true,
            boardType: "JADE_V1_1",
            jadeConfig: nil,
            jadeFeatures: nil,
            idfVersion: nil,
            chipFeatures: nil,
            efuseMac: efuseMac,
            batteryStatus: nil,
            jadeOtaMaxChunk: nil
        )
    }

    static func accountExport(xpub: String = xpub) -> JadeAccountExport {
        JadeAccountExport(
            masterFingerprint: "deadbeef",
            accountIndex: 0,
            accounts: [JadeAccount(variant: .wpkh, xpub: xpub, derivationPath: "m/84'/1'/0'")]
        )
    }

    static func device(path: String = blePath, name: String? = advertisedName) -> JadeDeviceInfo {
        JadeDeviceInfo(path: path, transport: .bluetooth, name: name, serialNumber: nil)
    }

    static func knownEntry(path: String = blePath, lastConnectedAt: Date = Date(timeIntervalSince1970: 0)) -> HwKnownDevice {
        HwKnownDevice(
            id: deviceId,
            name: advertisedName,
            path: path,
            transportType: "bluetooth",
            model: "Jade",
            lastConnectedAt: lastConnectedAt,
            xpubs: ["nativeSegwit": xpub],
            walletId: walletId,
            vendor: .blockstream,
            jadeDeviceId: efuseMac
        )
    }
}

/// A `JadeServicing` that answers from stubs and writes every call to a shared `JadeCallLog`. A call
/// with a gate waits for the gate to open, so a test can hold core mid-request.
final class FakeJadeService: JadeServicing, @unchecked Sendable {
    enum GatedCall: Hashable {
        case connect
        case unlock
        case disconnect
        case cancel
        case notifyDisconnected
    }

    struct Stubs {
        var isConnected = false
        var scanned: [JadeDeviceInfo] = []
        var scanError: Error?
        var listed: [JadeDeviceInfo] = []
        /// Answers to successive connects; once used up, `connectResult` answers every later one.
        var connectResults: [Result<JadeVersionInfo, Error>] = []
        var connectResult: Result<JadeVersionInfo, Error> = .success(JadeFixtures.version(.ready))
        var unlockError: Error?
        var refreshedVersion = JadeFixtures.version(.ready)
        var exportHandler: ([AccountType]) throws -> JadeAccountExport = { _ in JadeFixtures.accountExport() }
        var fingerprint = "deadbeef"
        /// Errors thrown by successive verifications; once used up, a verification succeeds.
        var verifyErrors: [Error] = []
        var signErrors: [Error] = []
        var signedPsbt = "signed"
        var completed = CompletedTransaction(serializedTx: "rawtx", txid: "txid")
    }

    struct Verification: Equatable {
        let network: JadeNetwork
        let variant: JadeAddressVariant
        let derivationPath: String
        let expectedAddress: String
    }

    struct Calls {
        var connectPaths: [String] = []
        var unlockNetworks: [JadeNetwork] = []
        var exportTypes: [[AccountType]] = []
        var verifications: [Verification] = []
        var signings: [String] = []
        var finalizations: [(original: String, signed: String)] = []
        var notifiedPaths: [String] = []
    }

    let log: JadeCallLog

    private let lock = NSLock()
    private var storedStubs = Stubs()
    private var recordedCalls = Calls()
    private var gates: [GatedCall: AsyncGate] = [:]

    init(log: JadeCallLog) {
        self.log = log
    }

    var stubs: Stubs {
        get { lock.withLock { storedStubs } }
        set { lock.withLock { storedStubs = newValue } }
    }

    var calls: Calls {
        lock.withLock { recordedCalls }
    }

    /// Makes every later `call` wait until the returned gate is opened.
    @discardableResult
    func gate(_ call: GatedCall) -> AsyncGate {
        lock.withLock {
            let gate = AsyncGate()
            gates[call] = gate
            return gate
        }
    }

    func initialize() async throws {
        log.record("service.initialize")
    }

    func scan(timeoutMs _: UInt32) async throws -> [JadeDeviceInfo] {
        log.record("service.scan")
        let stubs = stubs
        if let scanError = stubs.scanError {
            throw scanError
        }
        return stubs.scanned
    }

    func listDevices() async -> [JadeDeviceInfo] {
        log.record("service.list")
        return stubs.listed
    }

    func connect(path: String) async throws -> JadeVersionInfo {
        log.record("service.connect:\(path)")
        let result = lock.withLock {
            recordedCalls.connectPaths.append(path)
            return storedStubs.connectResults.isEmpty ? storedStubs.connectResult : storedStubs.connectResults.removeFirst()
        }
        await waitAtGate(.connect)
        return try result.get()
    }

    func disconnect() async throws {
        log.record("service.disconnect")
        await waitAtGate(.disconnect)
        log.record("service.disconnect.done")
    }

    func cancel() async throws {
        log.record("service.cancel")
        await waitAtGate(.cancel)
    }

    func notifyDisconnected(path: String) async {
        log.record("service.notifyDisconnected:\(path)")
        lock.withLock { recordedCalls.notifiedPaths.append(path) }
        await waitAtGate(.notifyDisconnected)
        log.record("service.notifyDisconnected.done")
    }

    func isConnected() -> Bool {
        stubs.isConnected
    }

    func refreshVersionInfo() async throws -> JadeVersionInfo {
        log.record("service.refresh")
        return stubs.refreshedVersion
    }

    func unlock(network: JadeNetwork) async throws {
        log.record("service.unlock")
        lock.withLock { recordedCalls.unlockNetworks.append(network) }
        await waitAtGate(.unlock)
        if let unlockError = stubs.unlockError {
            throw unlockError
        }
    }

    func getMasterFingerprint(network _: JadeNetwork) async throws -> String {
        log.record("service.fingerprint")
        return stubs.fingerprint
    }

    func getAccountExport(network _: JadeNetwork, accountTypes: [AccountType], accountIndex _: UInt32) async throws -> JadeAccountExport {
        log.record("service.export")
        lock.withLock { recordedCalls.exportTypes.append(accountTypes) }
        return try stubs.exportHandler(accountTypes)
    }

    func verifyAddress(network: JadeNetwork, variant: JadeAddressVariant, derivationPath: String, expectedAddress: String) async throws {
        log.record("service.verify")
        let error: Error? = lock.withLock {
            recordedCalls.verifications.append(
                Verification(network: network, variant: variant, derivationPath: derivationPath, expectedAddress: expectedAddress)
            )
            return storedStubs.verifyErrors.isEmpty ? nil : storedStubs.verifyErrors.removeFirst()
        }
        if let error {
            throw error
        }
    }

    func signPsbt(network _: JadeNetwork, psbtBase64: String) async throws -> String {
        log.record("service.sign")
        let error: Error? = lock.withLock {
            recordedCalls.signings.append(psbtBase64)
            return storedStubs.signErrors.isEmpty ? nil : storedStubs.signErrors.removeFirst()
        }
        if let error {
            throw error
        }
        return stubs.signedPsbt
    }

    func finalizePsbt(originalPsbt: String, signedPsbt: String) async throws -> CompletedTransaction {
        log.record("service.finalize")
        lock.withLock { recordedCalls.finalizations.append((originalPsbt, signedPsbt)) }
        return stubs.completed
    }

    private func waitAtGate(_ call: GatedCall) async {
        let gate = lock.withLock { gates[call] }
        await gate?.wait()
    }
}

/// A `JadeTransportControlling` that records every call to the shared log, with a gate for holding a
/// link close open.
final class FakeJadeTransportControl: JadeTransportControlling, @unchecked Sendable {
    let log: JadeCallLog
    let externalDisconnectSubject = PassthroughSubject<String, Never>()
    let poweredOnSubject = PassthroughSubject<Void, Never>()

    private let lock = NSLock()
    private var disconnectGate: AsyncGate?
    private var recordedPairedPaths: [Set<String>] = []

    init(log: JadeCallLog) {
        self.log = log
    }

    var externalDisconnects: AnyPublisher<String, Never> {
        externalDisconnectSubject.eraseToAnyPublisher()
    }

    var bluetoothPoweredOn: AnyPublisher<Void, Never> {
        poweredOnSubject.eraseToAnyPublisher()
    }

    /// Every set of paired paths pushed, oldest first.
    var pairedPathUpdates: [Set<String>] {
        lock.withLock { recordedPairedPaths }
    }

    /// Makes every later link close wait until the returned gate is opened.
    @discardableResult
    func gateDisconnects() -> AsyncGate {
        lock.withLock {
            let gate = AsyncGate()
            disconnectGate = gate
            return gate
        }
    }

    func disconnectDevice(path: String) async {
        log.record("transport.disconnect:\(path)")
        let gate = lock.withLock { disconnectGate }
        await gate?.wait()
        log.record("transport.disconnect.done:\(path)")
    }

    func closeAllConnections() async {
        log.record("transport.closeAll")
    }

    func releaseAllImmediately() {
        log.record("transport.releaseAll")
    }

    func setPairedPaths(_ paths: Set<String>) {
        lock.withLock { recordedPairedPaths.append(paths) }
    }
}

/// The Jade slice of the paired-device store, in memory.
final class InMemoryJadeKnownDeviceStore: JadeKnownDeviceStoring {
    var devices: [HwKnownDevice]
    var pendingNames: [String: String] = [:]
    private(set) var saves: [[HwKnownDevice]] = []
    private(set) var pendingNameUpdates: [PendingHwWalletName?] = []

    init(devices: [HwKnownDevice] = []) {
        self.devices = devices
    }

    func loadAll() -> [HwKnownDevice] {
        devices.sorted { $0.lastConnectedAt > $1.lastConnectedAt }
    }

    func saveAll(_ devices: [HwKnownDevice], pendingName: PendingHwWalletName?) {
        if let pendingName {
            setPendingName(walletId: pendingName.walletId, name: pendingName.name)
        }
        pendingNameUpdates.append(pendingName)
        saves.append(devices)
        self.devices = devices
    }

    func loadPendingNames() -> [String: String] {
        let named = Set(devices.filter { $0.customLabel?.isEmpty == false }.compactMap(\.resolvedWalletId))
        return pendingNames.filter { !named.contains($0.key) }
    }

    func setPendingName(walletId: String, name: String?) {
        pendingNames[walletId] = name.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A `BackgroundTaskScheduling` that hands out identifiers and keeps the expiration handler, so a test
/// can run out the background time on demand.
@MainActor
final class FakeBackgroundTasks: BackgroundTaskScheduling {
    var backgroundTimeRemaining: TimeInterval = 100
    var grantsTasks = true
    private(set) var begun: [UIBackgroundTaskIdentifier] = []
    private(set) var ended: [UIBackgroundTaskIdentifier] = []
    private var expirationHandlers: [UIBackgroundTaskIdentifier: @MainActor () -> Void] = [:]
    private var nextIdentifier = 1

    func beginBackgroundTask(named _: String, expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        guard grantsTasks else { return .invalid }
        let identifier = UIBackgroundTaskIdentifier(rawValue: nextIdentifier)
        nextIdentifier += 1
        begun.append(identifier)
        expirationHandlers[identifier] = expiration
        return identifier
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        ended.append(identifier)
        expirationHandlers[identifier] = nil
    }

    /// Runs the expiration handler of every task still running, as the system does when time is up.
    func expire() {
        for handler in expirationHandlers.values {
            handler()
        }
    }
}
