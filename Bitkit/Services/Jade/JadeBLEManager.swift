import Combine
import CoreBluetooth
import Foundation

struct JadeBLEDiscovery: Equatable {
    let path: String
    let name: String
}

/// The Bluetooth byte pipe `JadeTransport` drives for core. The blocking calls run on Rust blocking
/// threads, never on the main thread or the CoreBluetooth queue.
protocol JadeBLEDriving: AnyObject, Sendable {
    /// Paths whose link dropped without the app closing it: out of range, switched off, Bluetooth off.
    var externalDisconnects: AnyPublisher<String, Never> { get }
    /// Fires when Bluetooth turns back on after having been off, reset or unavailable.
    var bluetoothPoweredOn: AnyPublisher<Void, Never> { get }

    /// Scans for Jades advertising the Nordic UART Service, blocking for `duration`.
    func scan(duration: TimeInterval) -> [JadeBLEDiscovery]
    /// Connects, subscribes to notifications and learns the chunk size, blocking until the link is usable.
    func open(path: String) throws
    /// Releases the link, waiting briefly for the disconnect. A no-op for a path that is not open.
    func close(path: String)
    /// Writes one chunk with response, blocking until the Jade acknowledges it.
    func write(path: String, data: Data) throws
    /// Returns what has arrived, waiting at most `timeout`. Empty means nothing arrived yet.
    func read(path: String, timeout: TimeInterval) throws -> Data
    func chunkSize(path: String) -> UInt32
    func closeAll()
    /// Cancels every link without waiting, for an app about to be suspended or terminated.
    func releaseAllImmediately()
    /// Paths that were paired before, so a stalled setup on one of them points at a stale bond.
    func setPairedPaths(_ paths: Set<String>)
}

/// CoreBluetooth access for Jade, over the Nordic UART Service.
///
/// Separate from `TrezorBLEManager` with a central of its own: the two vendors differ in almost every
/// Bluetooth rule, and neither may disturb the other's links or scan results. The central is created
/// only by `scan` and `open`, so nothing prompts for Bluetooth before a Jade is actually used.
///
/// Every CoreBluetooth call runs on `centralQueue`, where the delegate callbacks arrive too. One lock
/// guards the manager's state and is never held while waiting, including while dispatching
/// synchronously onto `centralQueue`, whose callbacks take the same lock.
final class JadeBLEManager: NSObject, JadeBLEDriving, @unchecked Sendable {
    static let shared = JadeBLEManager()

    static let serviceUUID = CBUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e")
    static let writeCharacteristicUUID = CBUUID(string: "6e400002-b5a3-f393-e0a9-e50e24dcca9e")
    static let notifyCharacteristicUUID = CBUUID(string: "6e400003-b5a3-f393-e0a9-e50e24dcca9e")
    /// jade-client-rs `MAX_CHUNK_BYTES`.
    static let maxChunkSize: UInt32 = 509
    /// A default ATT MTU of 23 less the 3 byte header.
    static let defaultChunkSize: UInt32 = 20
    static let fallbackName = "Jade"

    private static let settleTimeout: TimeInterval = 2
    private static let connectTimeout: TimeInterval = 15
    private static let discoveryTimeout: TimeInterval = 10
    /// iOS pairs on the first encrypted access, which can be this subscription, so the budget covers
    /// the passkey being confirmed on the Jade and in the iOS pairing dialog.
    private static let subscribeTimeout: TimeInterval = 35
    /// Same budget as the subscription, since the pairing dialog can instead appear on the first write.
    private static let writeTimeout: TimeInterval = 35
    private static let disconnectTimeout: TimeInterval = 3
    private static let peripheralCacheLimit = 32
    private static let logContext = "JadeBLE"

    private final class Link {
        let peripheral: CBPeripheral
        let state: JadeBLELinkState
        var writeCharacteristic: CBCharacteristic?

        init(peripheral: CBPeripheral, state: JadeBLELinkState) {
            self.peripheral = peripheral
            self.state = state
        }
    }

    private struct CachedPeripheral {
        let peripheral: CBPeripheral
        let lastSeen: Date
    }

    private final class ScanSession {
        let finished = BLEOneShot()
        private(set) var discoveries: [JadeBLEDiscovery] = []

        /// True when the path was not listed yet.
        func upsert(_ discovery: JadeBLEDiscovery) -> Bool {
            if let index = discoveries.firstIndex(where: { $0.path == discovery.path }) {
                discoveries[index] = discovery
                return false
            }
            discoveries.append(discovery)
            return true
        }

        func remove(path: String) {
            discoveries.removeAll { $0.path == path }
        }
    }

    private let centralQueue = DispatchQueue(label: "jade.ble.central", qos: .userInitiated)
    private let centralQueueKey = DispatchSpecificKey<Void>()
    private let centralCreationLock = NSLock()
    private let stateLock = NSLock()

    private var central: CBCentralManager?
    private var centralState: CBManagerState = .unknown
    private var sawBluetoothUnavailable = false
    private var stateWaiters: [BLEOneShot] = []
    private var peripheralCache: [String: CachedPeripheral] = [:]
    private var advertisedNames: [String: String] = [:]
    private var scanSession: ScanSession?
    private var links: [String: Link] = [:]
    private var pairedPaths: Set<String> = []
    private var lastGeneration: UInt64 = 0

    private let externalDisconnectSubject = PassthroughSubject<String, Never>()
    private let poweredOnSubject = PassthroughSubject<Void, Never>()

    override init() {
        super.init()
        centralQueue.setSpecific(key: centralQueueKey, value: ())
    }

    var externalDisconnects: AnyPublisher<String, Never> {
        externalDisconnectSubject.eraseToAnyPublisher()
    }

    var bluetoothPoweredOn: AnyPublisher<Void, Never> {
        poweredOnSubject.eraseToAnyPublisher()
    }

    /// Whether the central exists yet. Only `scan` and `open` create it.
    var hasCentral: Bool {
        stateLock.withLock { central != nil }
    }

    static func chunkSize(maximumWriteLength: Int) -> UInt32 {
        UInt32(min(max(maximumWriteLength, 1), Int(maxChunkSize)))
    }

    /// Maps the CoreBluetooth errors that mean the Bluetooth bond is broken or was never confirmed.
    /// Nil for any other error, which the caller reports with its own description.
    static func pairingError(for error: Error?, isPaired: Bool) -> JadeBLEError? {
        guard let error else { return nil }
        let nsError = error as NSError
        switch (nsError.domain, nsError.code) {
        case (CBErrorDomain, CBError.Code.peerRemovedPairingInformation.rawValue):
            return .staleBond
        case (CBErrorDomain, CBError.Code.encryptionTimedOut.rawValue):
            return .pairingNotConfirmed
        case (CBATTErrorDomain, CBATTError.Code.insufficientEncryption.rawValue),
             (CBATTErrorDomain, CBATTError.Code.insufficientAuthentication.rawValue):
            return isPaired ? .staleBond : .pairingNotConfirmed
        default:
            return nil
        }
    }

    static func isJadeName(_ name: String?) -> Bool {
        guard let name else { return true }
        return name.range(of: fallbackName, options: [.caseInsensitive, .anchored]) != nil
    }

    // MARK: - Scanning

    func scan(duration: TimeInterval) -> [JadeBLEDiscovery] {
        dispatchPrecondition(condition: .notOnQueue(centralQueue))
        let central = startCentral()
        let state = waitForSettledState()
        guard state == .poweredOn else {
            Logger.debug("Skipped the Jade scan, Bluetooth state is \(state.rawValue)", context: Self.logContext)
            return []
        }

        let session = ScanSession()
        let replaced: ScanSession? = stateLock.withLock {
            let previous = scanSession
            scanSession = session
            return previous
        }
        replaced?.finished.resolve(.success(()))

        centralQueue.async {
            guard central.state == .poweredOn else { return }
            central.scanForPeripherals(
                withServices: [Self.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
        _ = session.finished.wait(timeout: duration)

        let (discoveries, isCurrentScan): ([JadeBLEDiscovery], Bool) = stateLock.withLock {
            guard scanSession === session else { return (session.discoveries, false) }
            scanSession = nil
            return (session.discoveries, true)
        }
        if isCurrentScan {
            centralQueue.async {
                guard central.state == .poweredOn else { return }
                central.stopScan()
            }
        }
        Logger.debug("Jade scan found \(discoveries.count) device(s)", context: Self.logContext)
        return discoveries
    }

    // MARK: - Opening

    func open(path: String) throws {
        dispatchPrecondition(condition: .notOnQueue(centralQueue))
        guard let identifier = HwDevicePath.bleIdentifier(path) else {
            throw JadeBLEError.invalidPath(path)
        }

        if let existing = link(for: path) {
            if existing.state.reuseIfUsable() {
                Logger.info("Reused the open Jade link \(path)", context: Self.logContext)
                return
            }
            close(path: path)
        }

        let central = startCentral()
        try requirePoweredOn(waitForSettledState())

        guard let peripheral = cachedPeripheral(path: path) ?? retrievePeripheral(identifier, path: path, central: central) else {
            throw JadeBLEError.deviceNotFound
        }

        let link = registerLink(path: path, peripheral: peripheral)
        do {
            try establish(link, path: path, central: central)
        } catch {
            let failure = error as? JadeBLEError ?? .connectFailed(error.localizedDescription)
            Logger.warn("Could not open the Jade link \(path): \(failure.localizedDescription)", context: Self.logContext)
            // Always cancel, even when setup failed after connecting: a Jade whose central went away
            // without disconnecting can refuse new connections until it is restarted.
            shutDown(link, path: path)
            throw failure
        }
    }

    private func establish(_ link: Link, path: String, central: CBCentralManager) throws {
        let peripheral = link.peripheral

        if onCentralQueue({ peripheral.state != .disconnected }) {
            Logger.debug("Releasing a leftover connection to \(path) before dialling", context: Self.logContext)
            let released = link.state.begin(.disconnect)
            centralQueue.async { Self.cancelConnection(to: peripheral, on: central) }
            if released.wait(timeout: Self.disconnectTimeout) == nil {
                link.state.abandon(.disconnect, released)
                Logger.warn("The leftover connection to \(path) did not report a disconnect", context: Self.logContext)
            }
        }

        let connected = link.state.begin(.connect)
        centralQueue.async { [weak self] in
            guard let self, isCurrent(link, path: path) else { return }
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
        try wait(for: connected, step: .connect, link: link, timeout: Self.connectTimeout, timeoutError: .connectTimeout)

        let servicesFound = link.state.begin(.services)
        centralQueue.async { [weak self] in
            guard let self, isCurrent(link, path: path) else { return }
            peripheral.discoverServices([Self.serviceUUID])
        }
        try wait(for: servicesFound, step: .services, link: link, timeout: Self.discoveryTimeout, timeoutError: .notAJade)
        guard let service = onCentralQueue({ peripheral.services?.first { $0.uuid == Self.serviceUUID } }) else {
            Logger.warn("\(path) does not offer the Nordic UART Service", context: Self.logContext)
            throw JadeBLEError.notAJade
        }

        let characteristicsFound = link.state.begin(.characteristics)
        centralQueue.async { [weak self] in
            guard let self, isCurrent(link, path: path) else { return }
            peripheral.discoverCharacteristics([Self.writeCharacteristicUUID, Self.notifyCharacteristicUUID], for: service)
        }
        try wait(for: characteristicsFound, step: .characteristics, link: link, timeout: Self.discoveryTimeout, timeoutError: .notAJade)
        let (writeCharacteristic, notifyCharacteristic) = onCentralQueue {
            (
                service.characteristics?.first { $0.uuid == Self.writeCharacteristicUUID },
                service.characteristics?.first { $0.uuid == Self.notifyCharacteristicUUID }
            )
        }
        // Write without response silently drops chunks on the Jade's GATT stack.
        guard let writeCharacteristic, writeCharacteristic.properties.contains(.write) else {
            Logger.warn("\(path) offers no write with response characteristic", context: Self.logContext)
            throw JadeBLEError.notAJade
        }
        // Real hardware offers indications only on its TX characteristic; iOS subscribes to either.
        guard let notifyCharacteristic, !notifyCharacteristic.properties.isDisjoint(with: [.notify, .indicate]) else {
            Logger.warn("\(path) offers no notify or indicate characteristic", context: Self.logContext)
            throw JadeBLEError.notAJade
        }

        let subscribed = link.state.begin(.subscribe)
        centralQueue.async { [weak self] in
            guard let self, isCurrent(link, path: path) else { return }
            peripheral.setNotifyValue(true, for: notifyCharacteristic)
        }
        let unconfirmedPairing: JadeBLEError = isPaired(path) ? .staleBond : .pairingNotConfirmed
        try wait(for: subscribed, step: .subscribe, link: link, timeout: Self.subscribeTimeout, timeoutError: unconfirmedPairing)

        // The write-without-response length is the true MTU less the header, so a chunk never needs a
        // long write even though every chunk is written with response.
        let chunkSize = Self.chunkSize(maximumWriteLength: onCentralQueue { peripheral.maximumWriteValueLength(for: .withoutResponse) })
        stateLock.withLock { link.writeCharacteristic = writeCharacteristic }
        try link.state.markReady(chunkSize: chunkSize)
        Logger.info("Opened the Jade link \(path) with chunk size \(chunkSize)", context: Self.logContext)
    }

    private func wait(
        for waiter: BLEOneShot,
        step: JadeBLELinkState.Step,
        link: Link,
        timeout: TimeInterval,
        timeoutError: JadeBLEError
    ) throws {
        guard let result = waiter.wait(timeout: timeout) else {
            link.state.abandon(step, waiter)
            throw timeoutError
        }
        try result.get()
    }

    // MARK: - Reading and writing

    func write(path: String, data: Data) throws {
        dispatchPrecondition(condition: .notOnQueue(centralQueue))
        let (link, characteristic, isPaired): (Link?, CBCharacteristic?, Bool) = stateLock.withLock {
            (links[path], links[path]?.writeCharacteristic, pairedPaths.contains(path))
        }
        guard let link else { throw JadeBLEError.notOpen }
        guard link.state.isUsable, let characteristic else { throw JadeBLEError.disconnected }

        // No retries and no pause between chunks: the firmware drops a partly received message after
        // two seconds of silence.
        let written = link.state.begin(.write)
        centralQueue.async { [weak self] in
            guard let self, isCurrent(link, path: path) else { return }
            link.peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }

        guard let result = written.wait(timeout: Self.writeTimeout) else {
            link.state.abandon(.write, written)
            // The very first write stalling on a Jade paired before means it rejected the stored key and
            // the new pairing was not confirmed: only pairing afresh fixes that.
            if link.state.writesCompleted == 0, isPaired {
                Logger.warn("The first write to \(path) stalled on a paired Jade, its bond is stale", context: Self.logContext)
                throw JadeBLEError.staleBond
            }
            throw JadeBLEError.writeTimeout
        }
        if case let .failure(error) = result {
            let failure = error as? JadeBLEError ?? .writeFailed(error.localizedDescription)
            switch failure {
            case .staleBond, .pairingNotConfirmed, .closed:
                throw failure
            default:
                throw link.state.isLinkUp ? failure : JadeBLEError.disconnected
            }
        }
        link.state.recordWrite()
        Logger.debug("Wrote \(data.count) bytes to \(path)", context: Self.logContext)
    }

    func read(path: String, timeout: TimeInterval) throws -> Data {
        dispatchPrecondition(condition: .notOnQueue(centralQueue))
        guard let link = link(for: path) else { throw JadeBLEError.notOpen }
        switch link.state.read(timeout: timeout) {
        case let .data(data):
            Logger.debug("Read \(data.count) bytes from \(path)", context: Self.logContext)
            return data
        case .empty:
            return Data()
        case .down:
            throw JadeBLEError.disconnected
        }
    }

    func chunkSize(path: String) -> UInt32 {
        link(for: path)?.state.chunkSize ?? Self.defaultChunkSize
    }

    // MARK: - Closing

    func close(path: String) {
        dispatchPrecondition(condition: .notOnQueue(centralQueue))
        guard let link = link(for: path) else { return }
        shutDown(link, path: path)
    }

    func closeAll() {
        dispatchPrecondition(condition: .notOnQueue(centralQueue))
        let snapshot = stateLock.withLock { links }
        for (path, link) in snapshot {
            shutDown(link, path: path)
        }
    }

    func releaseAllImmediately() {
        let (released, releasingCentral): ([Link], CBCentralManager?) = stateLock.withLock {
            let released = Array(links.values)
            links.removeAll()
            return (released, central)
        }
        guard !released.isEmpty else { return }
        for link in released where link.state.beginClosing() {
            link.state.finishClosing()
        }
        if let releasingCentral {
            onCentralQueue {
                for link in released {
                    Self.cancelConnection(to: link.peripheral, on: releasingCentral)
                }
            }
        }
        Logger.info("Released \(released.count) Jade link(s) without waiting", context: Self.logContext)
    }

    func setPairedPaths(_ paths: Set<String>) {
        stateLock.withLock { pairedPaths = paths }
    }

    /// Closing marks the link first, so the disconnect it causes is never reported as external.
    private func shutDown(_ link: Link, path: String) {
        guard link.state.beginClosing() else {
            link.state.waitUntilClosed(timeout: Self.disconnectTimeout)
            return
        }
        let disconnected = link.state.begin(.disconnect)
        let mustWait = link.state.isLinkUp
        if let central = stateLock.withLock({ central }) {
            centralQueue.async { Self.cancelConnection(to: link.peripheral, on: central) }
        }
        if mustWait, disconnected.wait(timeout: Self.disconnectTimeout) == nil {
            Logger.warn("The Jade link \(path) did not report a disconnect in time", context: Self.logContext)
        }
        link.state.abandon(.disconnect, disconnected)
        stateLock.withLock {
            if links[path] === link {
                links[path] = nil
            }
        }
        link.state.finishClosing()
        Logger.info("Closed the Jade link \(path)", context: Self.logContext)
    }

    // MARK: - Helpers

    private func startCentral() -> CBCentralManager {
        centralCreationLock.withLock {
            if let existing = stateLock.withLock({ central }) {
                return existing
            }
            // The app shows its own Bluetooth guidance, so the system power alert stays off.
            let created = CBCentralManager(
                delegate: self,
                queue: centralQueue,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
            stateLock.withLock { central = created }
            Logger.debug("Started the Jade Bluetooth central", context: Self.logContext)
            return created
        }
    }

    /// Waits up to `settleTimeout` while the state is still unknown or resetting, as it is right after
    /// the central is created or while the permission prompt is showing.
    private func waitForSettledState() -> CBManagerState {
        let waiter = BLEOneShot()
        let settled: CBManagerState? = stateLock.withLock {
            if Self.isSettled(centralState) {
                return centralState
            }
            stateWaiters.append(waiter)
            return nil
        }
        if let settled {
            return settled
        }
        _ = waiter.wait(timeout: Self.settleTimeout)
        return stateLock.withLock {
            stateWaiters.removeAll { $0 === waiter }
            return centralState
        }
    }

    /// Call on `centralQueue`. With Bluetooth off no connection is left to cancel, and CoreBluetooth
    /// rejects the call as misuse.
    private static func cancelConnection(to peripheral: CBPeripheral, on central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    private static func isSettled(_ state: CBManagerState) -> Bool {
        state != .unknown && state != .resetting
    }

    private func requirePoweredOn(_ state: CBManagerState) throws {
        switch state {
        case .poweredOn:
            return
        case .poweredOff:
            throw JadeBLEError.bluetoothOff
        case .unauthorized:
            throw JadeBLEError.bluetoothUnauthorized
        case .unsupported:
            throw JadeBLEError.bluetoothUnsupported
        default:
            throw JadeBLEError.bluetoothNotReady
        }
    }

    /// Runs `work` on `centralQueue` and returns its result. Must never be called while holding
    /// `stateLock`, since the delegate callbacks queued ahead of `work` take that lock.
    private func onCentralQueue<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: centralQueueKey) != nil {
            return work()
        }
        return centralQueue.sync(execute: work)
    }

    private func link(for path: String) -> Link? {
        stateLock.withLock { links[path] }
    }

    private func isCurrent(_ link: Link, path: String) -> Bool {
        stateLock.withLock { links[path] === link } && !link.state.isClosing
    }

    private func isPaired(_ path: String) -> Bool {
        stateLock.withLock { pairedPaths.contains(path) }
    }

    private func registerLink(path: String, peripheral: CBPeripheral) -> Link {
        let (link, displaced): (Link, Link?) = stateLock.withLock {
            lastGeneration &+= 1
            let link = Link(peripheral: peripheral, state: JadeBLELinkState(generation: lastGeneration))
            return (link, links.updateValue(link, forKey: path))
        }
        if let displaced, displaced.state.beginClosing() {
            Logger.warn("Replaced a Jade link to \(path) that was still being set up", context: Self.logContext)
            displaced.state.finishClosing()
        }
        return link
    }

    private func cachedPeripheral(path: String) -> CBPeripheral? {
        stateLock.withLock { peripheralCache[path]?.peripheral }
    }

    private func retrievePeripheral(_ identifier: UUID, path: String, central: CBCentralManager) -> CBPeripheral? {
        guard let peripheral = onCentralQueue({ central.retrievePeripherals(withIdentifiers: [identifier]).first }) else {
            return nil
        }
        stateLock.withLock { cachePeripheralLocked(peripheral, path: path) }
        return peripheral
    }

    private func cachePeripheralLocked(_ peripheral: CBPeripheral, path: String) {
        peripheralCache[path] = CachedPeripheral(peripheral: peripheral, lastSeen: Date())
        guard peripheralCache.count > Self.peripheralCacheLimit else { return }
        let oldestIdle = peripheralCache
            .filter { links[$0.key] == nil }
            .min { $0.value.lastSeen < $1.value.lastSeen }
        if let oldestIdle {
            peripheralCache[oldestIdle.key] = nil
        }
    }

    private func delegateTarget(for peripheral: CBPeripheral) -> (link: Link, isPaired: Bool)? {
        let path = HwDevicePath.ble(peripheral.identifier)
        return stateLock.withLock {
            guard let link = links[path] else { return nil }
            return (link, pairedPaths.contains(path))
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension JadeBLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Logger.debug("Bluetooth state is \(state.rawValue)", context: Self.logContext)

        let (waiters, droppedLinks, endedScan, isBackOn): ([BLEOneShot], [String: Link], ScanSession?, Bool) = stateLock.withLock {
            centralState = state
            var waiters: [BLEOneShot] = []
            if Self.isSettled(state) {
                waiters = stateWaiters
                stateWaiters.removeAll()
            }
            if state == .poweredOn {
                let isBackOn = sawBluetoothUnavailable
                sawBluetoothUnavailable = false
                return (waiters, [:], nil, isBackOn)
            }
            if state != .unknown {
                sawBluetoothUnavailable = true
            }
            return (waiters, links, scanSession, false)
        }

        for waiter in waiters {
            waiter.resolve(.success(()))
        }
        endedScan?.finished.resolve(.success(()))
        // iOS does not promise a disconnect callback per peripheral when Bluetooth goes away.
        let reason: JadeBLEError = state == .poweredOff ? .bluetoothOff : .disconnected
        for (path, link) in droppedLinks where link.state.markDown(reason: reason) {
            externalDisconnectSubject.send(path)
        }
        if isBackOn {
            Logger.info("Bluetooth is back on", context: Self.logContext)
            poweredOnSubject.send(())
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi _: NSNumber
    ) {
        let path = HwDevicePath.ble(peripheral.identifier)
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let newlyFound: String? = stateLock.withLock {
            // The scan response carries "Jade XXXXXX"; a later packet without a name keeps it.
            if let advertisedName {
                advertisedNames[path] = advertisedName
            }
            let name = advertisedNames[path] ?? peripheral.name
            // The Nordic UART Service is not unique to Jade, so other gadgets offering it are skipped.
            guard Self.isJadeName(name) else {
                scanSession?.remove(path: path)
                return nil
            }
            cachePeripheralLocked(peripheral, path: path)
            let discovery = JadeBLEDiscovery(path: path, name: name ?? Self.fallbackName)
            return scanSession?.upsert(discovery) == true ? discovery.name : nil
        }
        if let newlyFound {
            Logger.debug("Found \(newlyFound) at \(path)", context: Self.logContext)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let path = HwDevicePath.ble(peripheral.identifier)
        if let target = delegateTarget(for: peripheral), target.link.state.markConnected() {
            Logger.debug("Connected to \(path)", context: Self.logContext)
            return
        }
        Logger.info("Cancelling a connection to \(path) nobody is waiting for", context: Self.logContext)
        central.cancelPeripheralConnection(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let target = delegateTarget(for: peripheral) else { return }
        let failure = Self.pairingError(for: error, isPaired: target.isPaired)
            ?? .connectFailed(error?.localizedDescription ?? "unknown error")
        let path = HwDevicePath.ble(peripheral.identifier)
        Logger.warn("Could not connect to \(path): \(failure.localizedDescription)", context: Self.logContext)
        target.link.state.resolve(.connect, error: failure)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let path = HwDevicePath.ble(peripheral.identifier)
        guard let target = delegateTarget(for: peripheral) else { return }
        let state = target.link.state
        guard state.isLinkUp else {
            // A leftover connection released before dialling, or a connect cancelled while pending.
            state.resolve(.disconnect, error: nil)
            return
        }

        let reason: JadeBLEError = if let pairingError = Self.pairingError(for: error, isPaired: target.isPaired) {
            pairingError
        } else if let error, !state.isReady {
            .connectFailed(error.localizedDescription)
        } else {
            .disconnected
        }
        if state.markDown(reason: reason) {
            Logger.info("The Jade link \(path) dropped: \(reason.localizedDescription)", context: Self.logContext)
            externalDisconnectSubject.send(path)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension JadeBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let target = delegateTarget(for: peripheral) else { return }
        let failure = error.map { Self.pairingError(for: $0, isPaired: target.isPaired) ?? .connectFailed($0.localizedDescription) }
        target.link.state.resolve(.services, error: failure)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard service.uuid == Self.serviceUUID, let target = delegateTarget(for: peripheral) else { return }
        let failure = error.map { Self.pairingError(for: $0, isPaired: target.isPaired) ?? .connectFailed($0.localizedDescription) }
        target.link.state.resolve(.characteristics, error: failure)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.notifyCharacteristicUUID, let target = delegateTarget(for: peripheral) else { return }
        let failure: JadeBLEError? = if let error {
            Self.pairingError(for: error, isPaired: target.isPaired) ?? .subscribeFailed(error.localizedDescription)
        } else if !characteristic.isNotifying {
            .subscribeFailed("notifications stayed off")
        } else {
            nil
        }
        target.link.state.resolve(.subscribe, error: failure)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.writeCharacteristicUUID, let target = delegateTarget(for: peripheral) else { return }
        let failure = error.map { Self.pairingError(for: $0, isPaired: target.isPaired) ?? .writeFailed($0.localizedDescription) }
        target.link.state.resolve(.write, error: failure)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == Self.notifyCharacteristicUUID, let value = characteristic.value else { return }
        delegateTarget(for: peripheral)?.link.state.enqueue(value)
    }
}
