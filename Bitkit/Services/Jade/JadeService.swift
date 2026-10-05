import BitkitCore
import Foundation

/// bitkit-core's Jade session, as `JadeManager` drives it.
protocol JadeServicing: AnyObject, Sendable {
    func initialize() async throws
    func scan(timeoutMs: UInt32) async throws -> [JadeDeviceInfo]
    /// The devices of the last scan, without scanning again.
    func listDevices() async -> [JadeDeviceInfo]
    func connect(path: String) async throws -> JadeVersionInfo
    func disconnect() async throws
    /// Aborts the request in flight, which then fails with `JadeError.UserCancelled`.
    func cancel() async throws
    /// Reports a link that dropped without core closing it. Must reach core before the next connect to
    /// the same path, or it tears that new session down.
    func notifyDisconnected(path: String) async
    func isConnected() -> Bool
    func refreshVersionInfo() async throws -> JadeVersionInfo
    func unlock(network: JadeNetwork) async throws
    func getMasterFingerprint(network: JadeNetwork) async throws -> String
    func getAccountExport(network: JadeNetwork, accountTypes: [AccountType], accountIndex: UInt32) async throws -> JadeAccountExport
    func verifyAddress(network: JadeNetwork, variant: JadeAddressVariant, derivationPath: String, expectedAddress: String) async throws
    /// Returns the signed PSBT, base64 encoded.
    func signPsbt(network: JadeNetwork, psbtBase64: String) async throws -> String
    func finalizePsbt(originalPsbt: String, signedPsbt: String) async throws -> CompletedTransaction
}

/// Thin wrapper over bitkit-core's `jade*` functions, each run through `ServiceQueue.background(.core)`.
///
/// A Swift task cancel never reaches Rust: aborting a request in flight takes `cancel()` or
/// `disconnect()`. `ServiceQueue` does not serialise async calls either, so ordering them is left to
/// `JadeManager`.
final class JadeService: JadeServicing, @unchecked Sendable {
    static let shared = JadeService()

    /// Matches the Trezor scan window, so one search pass stays predictable.
    static let scanTimeoutMs: UInt32 = 3000

    private static let logContext = "JadeService"

    private let transport: JadeTransportCallback
    private let callbackLock = NSLock()
    private var isCallbackRegistered = false

    init(transport: JadeTransportCallback = JadeTransport.shared) {
        self.transport = transport
    }

    func initialize() async throws {
        try await ServiceQueue.background(.core) { [self] in
            ensureCallbackRegistered()
        }
    }

    func scan(timeoutMs: UInt32) async throws -> [JadeDeviceInfo] {
        try await ServiceQueue.background(.core) { [self] in
            ensureCallbackRegistered()
            return try await jadeScan(timeoutMs: timeoutMs)
        }
    }

    func listDevices() async -> [JadeDeviceInfo] {
        let devices = try? await ServiceQueue.background(.core) {
            await jadeListDevices()
        }
        return devices ?? []
    }

    func connect(path: String) async throws -> JadeVersionInfo {
        try await ServiceQueue.background(.core) { [self] in
            ensureCallbackRegistered()
            return try await jadeConnect(transport: .bluetooth, path: path)
        }
    }

    func disconnect() async throws {
        try await ServiceQueue.background(.core) {
            try await jadeDisconnect()
        }
    }

    func cancel() async throws {
        try await ServiceQueue.background(.core) {
            try await jadeCancel()
        }
    }

    func notifyDisconnected(path: String) async {
        _ = try? await ServiceQueue.background(.core) {
            await jadeNotifyDisconnected(path: path)
        }
    }

    func isConnected() -> Bool {
        jadeIsConnected()
    }

    func refreshVersionInfo() async throws -> JadeVersionInfo {
        try await ServiceQueue.background(.core) {
            try await jadeRefreshVersionInfo()
        }
    }

    func unlock(network: JadeNetwork) async throws {
        try await ServiceQueue.background(.core) {
            try await jadeUnlock(network: network)
        }
    }

    func getMasterFingerprint(network: JadeNetwork) async throws -> String {
        try await ServiceQueue.background(.core) {
            try await jadeGetMasterFingerprint(network: network)
        }
    }

    func getAccountExport(network: JadeNetwork, accountTypes: [AccountType], accountIndex: UInt32) async throws -> JadeAccountExport {
        try await ServiceQueue.background(.core) {
            try await jadeGetAccountExport(network: network, accountIndex: accountIndex, accountTypes: accountTypes)
        }
    }

    func verifyAddress(network: JadeNetwork, variant: JadeAddressVariant, derivationPath: String, expectedAddress: String) async throws {
        try await ServiceQueue.background(.core) {
            try await jadeVerifyAddress(
                network: network,
                variant: variant,
                derivationPath: derivationPath,
                expectedAddress: expectedAddress
            )
        }
    }

    func signPsbt(network: JadeNetwork, psbtBase64: String) async throws -> String {
        try await ServiceQueue.background(.core) {
            try await jadeSignPsbt(network: network, psbt: psbtBase64)
        }
    }

    func finalizePsbt(originalPsbt: String, signedPsbt: String) async throws -> CompletedTransaction {
        try await ServiceQueue.background(.core) {
            // Module-qualified: unqualified, the name resolves to this method and it calls itself.
            try BitkitCore.finalizePsbt(originalPsbt: originalPsbt, signedPsbt: signedPsbt)
        }
    }

    private func ensureCallbackRegistered() {
        callbackLock.lock()
        defer { callbackLock.unlock() }

        guard !isCallbackRegistered else { return }
        if jadeSetTransportCallback(callback: transport) {
            Logger.warn("Replaced a previously registered Jade transport", context: Self.logContext)
        }
        isCallbackRegistered = true
        Logger.info("Jade transport registered", context: Self.logContext)
    }
}
