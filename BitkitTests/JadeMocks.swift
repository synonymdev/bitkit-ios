@testable import Bitkit
import Combine
import Foundation

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
