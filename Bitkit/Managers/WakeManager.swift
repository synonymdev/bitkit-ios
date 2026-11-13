import BitkitCore
import Foundation
import UIKit
import UserNotifications

/// Who registers for wakes. Registering links the node id, the Pubky key and the push token on the gateway, so a wallet
/// registers only once the user has turned notifications on and iOS allows them. Widen it here.
enum WakeRegistrationPolicy {
    static func allowsRegistration(
        authorizationStatus: UNAuthorizationStatus,
        notificationsEnabled: Bool,
        isE2E: Bool = Env.isE2E
    ) -> Bool {
        // E2E installs are wiped after each run and would leave dead push tokens behind.
        !isE2E && authorizationStatus == .authorized && notificationsEnabled
    }
}

/// The app state a registration is built from. A change to any of it registers again.
struct WakeRegistrationInputs: Hashable {
    var isNodeReady: Bool
    var pushToken: String?
    var authorizationStatus: UNAuthorizationStatus
    var notificationsEnabled: Bool
    var pubkyPublicKey: String?
}

enum WakeIdentitySelection: Equatable {
    case lightningOnly
    case lightningAndPubky(publicKeyZ32: String, secretKeyHex: String)
    /// The Pubky key cannot be read right now. Registering `ln:` alone would drop `pk:` and the grants tied to it.
    case skip
}

/// Leaves the Pubky secret out of logs and test failures.
extension WakeIdentitySelection: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        switch self {
        case .lightningOnly: "lightningOnly"
        case let .lightningAndPubky(publicKeyZ32, _): "lightningAndPubky(\(publicKeyZ32))"
        case .skip: "skip"
        }
    }

    var debugDescription: String {
        description
    }
}

enum WakeIdentityResolver {
    /// A wallet needs no Pubky profile, so `ln:` alone is valid. `pk:` is added only with a secret that signs for the
    /// signed-in pubky, and no key is derived for a wallet without a profile, which would register a key never published.
    static func select(
        profilePublicKey: String?,
        hasStoredIdentity: () throws -> Bool = { try PubkyProfileManager.hasStoredIdentity() },
        readSecretKeyHex: () throws -> String? = readActiveSecretKeyHex,
        derivePublicKey: (String) throws -> String = { try PubkyService.pubkyPublicKeyFromSecret(secretKeyHex: $0) }
    ) -> WakeIdentitySelection {
        guard let profilePublicKey else {
            // A stored identity without a public key is a profile still loading.
            guard let hasIdentity = try? hasStoredIdentity() else { return .skip }
            return hasIdentity ? .skip : .lightningOnly
        }
        guard let profileKey = PubkyPublicKeyFormat.normalized(profilePublicKey) else { return .lightningOnly }
        let secretKeyHex: String?
        do {
            secretKeyHex = try readSecretKeyHex()
        } catch {
            return .skip
        }
        guard let secretKeyHex, !secretKeyHex.isEmpty else { return .lightningOnly }
        guard let derived = try? derivePublicKey(secretKeyHex) else { return .skip }
        guard PubkyPublicKeyFormat.matches(derived, profileKey) else { return .lightningOnly }
        return .lightningAndPubky(publicKeyZ32: String(profileKey.dropFirst("pubky".count)), secretKeyHex: secretKeyHex)
    }

    static func identities(nodeId: String, selection: WakeIdentitySelection) -> [String] {
        var identities = ["ln:\(nodeId.lowercased())"]
        if case let .lightningAndPubky(publicKeyZ32, _) = selection {
            identities.append("pk:\(publicKeyZ32)")
        }
        return identities
    }

    /// Bitkit's own key, or else the adopted app's, read on demand from `pubky.shared`. Unlike
    /// `PubkyProfileManager.activeSecretKeyHex`, a keychain that cannot be read throws rather than reading as no key.
    static func readActiveSecretKeyHex() throws -> String? {
        if let local = try Keychain.loadString(key: .pubkySecretKey), !local.isEmpty {
            return local
        }
        guard let adopted = AdoptedPubkyReference.current else { return nil }
        return try SharedPubkyKeychain.readSecret(sourceApp: adopted.sourceApp, pubky: adopted.pubky)
    }
}

enum WakeRegistrationResult: Equatable {
    case notConfigured
    case notAllowed
    case waitingForNode
    case waitingForPushToken
    case waitingForIdentity
    case unchanged
    case registered(deviceId: String, unknownTopics: [String])
    case failed(String)
}

enum WakeConfig {
    static let app = "bitkit"
    /// Patterns, so a topic the gateway adds to a subscribed namespace arrives without an app release. `wake.test` needs
    /// no subscription: the gateway sends it to the device that asked for it.
    static let topics = ["paykit.*", "swap.*"]
    static let presenceTtlSecs: UInt32 = 90
    static let presenceRenewal: Duration = .seconds(60)
    /// iOS gives a background push 30 seconds.
    static let backgroundPushTimeout: Duration = .seconds(25)

    /// `Bitkit.entitlements` says `development` for both configurations, so it cannot tell which APNs environment
    /// issued the token. A wrong environment fails every push.
    static var environment: WakeEnvironment {
        Env.isDebug ? .sandbox : .production
    }

    static var environmentName: String {
        environment == .sandbox ? "sandbox" : "production"
    }
}

/// When to try a registration again after it failed. Only network failures, 5xx and 429 are tried again; any other
/// answer would come back the same.
enum WakeRetry {
    static let firstDelaySecs: UInt64 = 30
    static let maxDelaySecs: UInt64 = 900
    /// The longest a 429's `Retry-After` is followed.
    static let maxRetryAfterSecs: UInt64 = 3600

    /// Seconds to wait before attempt `attempt + 1`, or nil when trying again cannot help.
    static func delaySecs(after error: Error, attempt: Int) -> UInt64? {
        let retryAfterSecs: UInt64?
        switch error {
        case WakeError.RequestFailed:
            retryAfterSecs = nil
        case let WakeError.GatewayRejected(status, _, _, _, retryAfter) where status == 429 || status >= 500:
            retryAfterSecs = retryAfter
        default:
            return nil
        }
        let backoff = min(maxDelaySecs, firstDelaySecs << UInt64(min(max(attempt, 0), 5)))
        return max(backoff, min(retryAfterSecs ?? 0, maxRetryAfterSecs))
    }

    /// Runs `operation` until it returns without an error that is worth trying again, waiting between attempts.
    /// Cancelling the task stops it, with the last result.
    static func run<T>(
        sleep: (UInt64) async throws -> Void = { try await Task.sleep(for: .seconds(Int64($0))) },
        _ operation: () async -> (result: T, error: Error?)
    ) async -> T {
        var attempt = 0
        while true {
            let (result, error) = await operation()
            guard let error, let delay = delaySecs(after: error, attempt: attempt) else { return result }
            Logger.info("Trying the wake registration again in \(delay) s", context: "Wake")
            do {
                try await sleep(delay)
            } catch {
                return result
            }
            attempt += 1
        }
    }
}

extension WakeHandlerRegistry {
    /// Background wakes the app delegate handles. Any other topic is acknowledged `noHandler`.
    static let app = WakeHandlerRegistry([:])
}

/// Sends a registration unless the gateway already holds the same one, signed at a timestamp that only increases.
struct WakeRegistrar {
    enum Outcome: Equatable {
        case unchanged
        case registered(WakeRegistration)
    }

    typealias Sign = (WakeRegistrationRequest) async throws -> [WakeIdentityProof]
    typealias Send = (_ gatewayUrl: String, _ request: WakeRegistrationRequest, _ proofs: [WakeIdentityProof]) async throws
        -> WakeRegistration

    let gatewayUrl: String
    var serverInfo: (_ gatewayUrl: String) async throws -> WakeServerInfo = { gatewayUrl in
        try await ServiceQueue.background(.core, wrapErrors: false) {
            try await wakeServerInfo(gatewayUrl: gatewayUrl)
        }
    }

    var send: Send = { gatewayUrl, request, proofs in
        try await ServiceQueue.background(.core, wrapErrors: false) {
            try await wakeRegister(gatewayUrl: gatewayUrl, request: request, proofs: proofs)
        }
    }

    var loadRegistration: () throws -> WakeRegistrationRecord = WakeStorage.loadRegistration
    var saveRegistration: (WakeRegistrationRecord) throws -> Void = WakeStorage.saveRegistration
    var now: () -> UInt64 = { WakeTimestamp.now }

    func register(
        credentials: WakeCredentials,
        pushToken: String,
        identities: [String],
        force: Bool,
        sign: Sign
    ) async throws -> Outcome {
        var record = try loadRegistration()
        let content = { (audience: String) in
            WakeRegistrationContent(
                audience: audience,
                environment: WakeConfig.environmentName,
                pushToken: pushToken,
                encryptionPublicKey: credentials.encryptionPublicKey,
                identities: identities,
                topics: WakeConfig.topics
            )
        }
        if !force, let device = record.device, device.gatewayUrl == gatewayUrl, device.content == content(device.content.audience) {
            return .unchanged
        }

        // The audience is the gateway's, never a constant.
        let info = try await serverInfo(gatewayUrl)
        let registeredDevice = WakeRegisteredDevice(gatewayUrl: gatewayUrl, content: content(info.audience))
        if !force, record.device == registeredDevice {
            return .unchanged
        }

        let lastTimestamp = record.lastTimestamp
        func attempt(_ timestamp: UInt64) async throws -> WakeRegistration {
            let request = try await ServiceQueue.background(.core, wrapErrors: false) {
                try wakePrepareRegistration(
                    audience: info.audience,
                    app: WakeConfig.app,
                    installId: credentials.installId,
                    platform: .apns,
                    environment: WakeConfig.environment,
                    pushToken: pushToken,
                    encryptionPublicKey: credentials.encryptionPublicKey,
                    secretSha256: credentials.deviceSecretSha256,
                    identities: identities,
                    topics: WakeConfig.topics,
                    timestamp: timestamp
                )
            }
            let proofs = try await sign(request)
            // Kept before sending, since the gateway may accept it even when its answer is lost. What it held before
            // then no longer counts as unchanged.
            record.lastTimestamp = request.timestamp
            record.sentToGatewayUrl = gatewayUrl
            if record.device != registeredDevice {
                record.device = nil
            }
            try saveRegistration(record)
            return try await send(gatewayUrl, request, proofs)
        }

        let registration: WakeRegistration
        do {
            registration = try await attempt(WakeTimestamp.next(now: now(), last: lastTimestamp))
        } catch let WakeError.GatewayRejected(401, "stale_timestamp", _, serverTime?, _)
            where WakeTimestamp.plausibleServerTimes.contains(serverTime)
        {
            Logger.warn("Wake gateway clock differs from the device's, signing again with its time", context: "Wake")
            registration = try await attempt(WakeTimestamp.retry(serverTime: serverTime, last: lastTimestamp))
        }

        record.device = registeredDevice
        try saveRegistration(record)
        return .registered(registration)
    }
}

/// Removes the install from the gateway that may hold it, including one whose registration answer was lost. A device
/// the gateway no longer knows counts as removed.
struct WakeUnregistrar {
    typealias Unregister = (_ gatewayUrl: String, _ deviceSecret: String) async throws -> Void

    var unregister: Unregister = { gatewayUrl, deviceSecret in
        try await ServiceQueue.background(.core, wrapErrors: false) {
            try await wakeUnregister(gatewayUrl: gatewayUrl, deviceSecret: deviceSecret)
        }
    }

    var loadRegistration: () throws -> WakeRegistrationRecord = WakeStorage.loadRegistration
    var saveRegistration: (WakeRegistrationRecord) throws -> Void = WakeStorage.saveRegistration
    var loadCredentials: () throws -> WakeCredentials? = WakeStorage.loadCredentials

    /// Returns false when no gateway may hold the install.
    func run() async throws -> Bool {
        var record = try loadRegistration()
        guard let gatewayUrl = record.registeredGatewayUrl, let credentials = try loadCredentials() else { return false }
        do {
            try await unregister(gatewayUrl, credentials.deviceSecret)
        } catch WakeError.GatewayRejected(401, _, _, _, _) {
            Logger.info("Wake gateway no longer knows this device", context: "Wake")
        }
        record.device = nil
        record.sentToGatewayUrl = nil
        try saveRegistration(record)
        return true
    }
}

enum WakeManagerError: LocalizedError {
    case notRegistered

    var errorDescription: String? {
        "This device is not registered with a wake gateway"
    }
}

/// Registers the device with the wake gateway, keeps its presence while the app is open, and handles the background wakes
/// the gateway pushes. Wakes stay off unless `Env.wakeGatewayUrl` names a gateway.
@MainActor
final class WakeManager {
    static let shared = WakeManager()

    private var latestInputs: WakeRegistrationInputs?
    private var queueTail: Task<Void, Never>?
    private var presenceTask: Task<Void, Never>?
    private var isSceneActive = false
    private var presenceClearTaskId = UIBackgroundTaskIdentifier.invalid

    private init() {}

    var gatewayUrl: String? {
        Env.wakeGatewayUrl
    }

    // MARK: - Registration

    @discardableResult
    func registerIfAllowed(_ inputs: WakeRegistrationInputs) async -> WakeRegistrationResult {
        latestInputs = inputs
        guard gatewayUrl != nil else { return .notConfigured }
        // Runs inside the scene's `.task(id:)`, so a change of inputs cancels the waiting.
        return await WakeRetry.run { await self.serialized { await self.register(force: false) } }
    }

    /// Registers again with the latest inputs even when nothing changed.
    func registerNow() async -> WakeRegistrationResult {
        await serialized { await self.register(force: true) }.result
    }

    private func register(force: Bool) async -> (result: WakeRegistrationResult, error: Error?) {
        let result: WakeRegistrationResult
        do {
            result = try await registerOrThrow(force: force)
        } catch {
            Logger.error("Failed to register for wakes: \(error)", context: "Wake")
            return (.failed(error.localizedDescription), error)
        }
        return (result, nil)
    }

    private func registerOrThrow(force: Bool) async throws -> WakeRegistrationResult {
        guard let gatewayUrl else { return .notConfigured }
        guard let inputs = latestInputs,
              WakeRegistrationPolicy.allowsRegistration(
                  authorizationStatus: inputs.authorizationStatus,
                  notificationsEnabled: inputs.notificationsEnabled
              )
        else { return .notAllowed }
        guard inputs.isNodeReady, let nodeId = LightningService.shared.nodeId else { return .waitingForNode }
        guard let pushToken = inputs.pushToken?.lowercased(), !pushToken.isEmpty else { return .waitingForPushToken }
        let selection = WakeIdentityResolver.select(profilePublicKey: inputs.pubkyPublicKey)
        guard selection != .skip else { return .waitingForIdentity }
        let identities = WakeIdentityResolver.identities(nodeId: nodeId, selection: selection)

        let credentials = try WakeStorage.loadOrCreateCredentials()
        let outcome = try await WakeRegistrar(gatewayUrl: gatewayUrl).register(
            credentials: credentials,
            pushToken: pushToken,
            identities: identities,
            force: force,
            sign: { request in try await Self.proofs(for: request, nodeId: nodeId, selection: selection) }
        )
        guard case let .registered(registration) = outcome else { return .unchanged }
        Logger.info(
            "Registered for wakes as \(registration.deviceId) with \(identities.map { $0.prefix(3) }.joined(separator: ", "))",
            context: "Wake"
        )
        if !registration.unknownTopics.isEmpty {
            Logger.warn("Wake gateway does not know topics \(registration.unknownTopics)", context: "Wake")
        }
        refreshPresence()
        return .registered(deviceId: registration.deviceId, unknownTopics: registration.unknownTopics)
    }

    private static func proofs(
        for request: WakeRegistrationRequest,
        nodeId: String,
        selection: WakeIdentitySelection
    ) async throws -> [WakeIdentityProof] {
        let lightningSignature = try await LightningService.shared.sign(message: request.message)
        var proofs = [WakeIdentityProof(identity: "ln:\(nodeId.lowercased())", signature: lightningSignature)]
        if case let .lightningAndPubky(publicKeyZ32, secretKeyHex) = selection {
            let pubkySignature = try await ServiceQueue.background(.core, wrapErrors: false) {
                try wakeSignPubkyProof(secretKeyHex: secretKeyHex, message: request.message)
            }
            proofs.append(WakeIdentityProof(identity: "pk:\(publicKeyZ32)", signature: pubkySignature))
        }
        return proofs
    }

    // MARK: - Unregistering

    /// Removes the device from the gateway it registered with, so its secret stops working and no wake reaches it. A
    /// device the gateway no longer knows counts as removed.
    func unregister() async {
        await serialized { await self.unregisterRegisteredDevice() }
    }

    private func unregisterRegisteredDevice() async {
        do {
            if try await WakeUnregistrar().run() {
                Logger.info("Unregistered from wakes", context: "Wake")
            }
        } catch {
            Logger.warn("Failed to unregister from wakes: \(error)", context: "Wake")
        }
    }

    // MARK: - Presence

    /// Tells the gateway the app is open, so it holds back wakes and fallback alerts meant for an app in the background.
    func sceneBecameActive() {
        isSceneActive = true
        endPresenceClearTask()
        let previous = presenceTask
        previous?.cancel()
        guard gatewayUrl != nil else {
            presenceTask = nil
            return
        }
        presenceTask = Task {
            await previous?.value
            while !Task.isCancelled {
                await setPresence()
                try? await Task.sleep(for: WakeConfig.presenceRenewal)
            }
        }
    }

    func sceneEnteredBackground() {
        isSceneActive = false
        let previous = presenceTask
        previous?.cancel()
        endPresenceClearTask()
        guard gatewayUrl != nil else {
            presenceTask = nil
            return
        }
        let clearTaskId = UIApplication.shared.beginBackgroundTask(withName: "Clear wake presence") {
            MainActor.assumeIsolated { self.endPresenceClearTask() }
        }
        presenceClearTaskId = clearTaskId
        presenceTask = Task {
            await previous?.value
            await clearPresence()
            endPresenceClearTask(clearTaskId)
        }
    }

    private func refreshPresence() {
        guard isSceneActive else { return }
        sceneBecameActive()
    }

    /// Ends the background task clearing presence, or only `identifier` when given, so an older clear cannot end a newer one.
    private func endPresenceClearTask(_ identifier: UIBackgroundTaskIdentifier? = nil) {
        guard presenceClearTaskId != .invalid, identifier == nil || identifier == presenceClearTaskId else { return }
        UIApplication.shared.endBackgroundTask(presenceClearTaskId)
        presenceClearTaskId = .invalid
    }

    private func setPresence() async {
        guard let install = try? registeredInstall() else { return }
        do {
            _ = try await ServiceQueue.background(.core, wrapErrors: false) {
                try await wakeSetPresence(gatewayUrl: install.gatewayUrl, deviceSecret: install.deviceSecret, ttlSecs: WakeConfig.presenceTtlSecs)
            }
        } catch {
            Logger.warn("Failed to set wake presence: \(error)", context: "Wake")
        }
    }

    private func clearPresence() async {
        guard let install = try? registeredInstall() else { return }
        do {
            try await ServiceQueue.background(.core, wrapErrors: false) {
                try await wakeClearPresence(gatewayUrl: install.gatewayUrl, deviceSecret: install.deviceSecret)
            }
        } catch {
            Logger.warn("Failed to clear wake presence: \(error)", context: "Wake")
        }
    }

    private struct RegisteredInstall {
        let gatewayUrl: String
        let deviceSecret: String
    }

    /// The device, while it is registered with the gateway this build is configured for.
    private func registeredInstall() throws -> RegisteredInstall? {
        guard let gatewayUrl, let device = try WakeStorage.loadRegistration().device, device.gatewayUrl == gatewayUrl,
              let credentials = try WakeStorage.loadCredentials()
        else { return nil }
        return RegisteredInstall(gatewayUrl: device.gatewayUrl, deviceSecret: credentials.deviceSecret)
    }

    // MARK: - Receiving

    /// Handles a background push for the app delegate, returning within the time iOS allows.
    func handleBackgroundPush(pushJson: String?) async -> UIBackgroundFetchResult {
        guard let pushJson else { return .noData }
        let receipt = await withDeadline(WakeConfig.backgroundPushTimeout) {
            await WakeReceiver(handlers: .app).receive(pushJson: pushJson)
        }
        return Self.fetchResult(for: receipt)
    }

    nonisolated static func fetchResult(for receipt: WakeReceipt?) -> UIBackgroundFetchResult {
        guard case let .acknowledged(_, _, outcome, _) = receipt else { return receipt == nil ? .failed : .noData }
        switch outcome {
        case .handled: return .newData
        case .noHandler: return .noData
        case .failed: return .failed
        }
    }

    // MARK: - Dev Settings

    func device() async throws -> WakeDevice {
        guard let install = try registeredInstall() else { throw WakeManagerError.notRegistered }
        return try await ServiceQueue.background(.core, wrapErrors: false) {
            try await wakeGetDevice(gatewayUrl: install.gatewayUrl, deviceSecret: install.deviceSecret)
        }
    }

    /// Asks the gateway to send `wake.test` to this device. Returns the wake id.
    func sendTestWake() async throws -> String {
        guard let install = try registeredInstall() else { throw WakeManagerError.notRegistered }
        return try await ServiceQueue.background(.core, wrapErrors: false) {
            try await wakeSendTest(gatewayUrl: install.gatewayUrl, deviceSecret: install.deviceSecret)
        }
    }

    // MARK: - Ordering

    /// Runs registrations and unregistrations one at a time, in the order they were asked for.
    private func serialized<T>(_ operation: @escaping @MainActor () async -> T) async -> T {
        let previous = queueTail
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        queueTail = Task { _ = await task.value }
        return await task.value
    }
}
