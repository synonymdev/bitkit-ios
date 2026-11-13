import BitkitCore
import Foundation

enum WakeTopics {
    /// The self-test the gateway sends to one device, as an alert.
    static let test = "wake.test"
}

enum WakePush {
    /// The APNs dictionary as the JSON `wakeDecryptPush` reads, or nil for a push that carries no wake.
    static func json(from userInfo: [AnyHashable: Any]) -> String? {
        let object = userInfo.reduce(into: [String: Any]()) { result, entry in
            if let key = entry.key as? String {
                result[key] = entry.value
            }
        }
        guard carriesWake(object), JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A v1 wake, a fallback alert or a legacy v0 envelope, the shapes `wakeDecryptPush` reads on APNs.
    private static func carriesWake(_ object: [String: Any]) -> Bool {
        if object["wake"] != nil || object["wake_fallback"] != nil {
            return true
        }
        let alert = (object["aps"] as? [String: Any])?["alert"] as? [String: Any]
        return alert?["payload"] != nil
    }

    static func decrypt(pushJson: String, secretKeyHex: String) async throws -> WakeEnvelope {
        try await ServiceQueue.background(.core, wrapErrors: false) {
            try wakeDecryptPush(secretKeyHex: secretKeyHex, pushJson: pushJson)
        }
    }
}

/// The work done for each topic. A topic without a handler is acknowledged `noHandler`, a handler that returns
/// `handled` and one that throws `failed`. Acknowledging `handled` cancels the topic's fallback alert, so a handler
/// returns only once its work is done.
struct WakeHandlerRegistry {
    typealias Handler = (WakeEnvelope) async throws -> Void

    private let handlers: [String: Handler]

    init(_ handlers: [String: Handler]) {
        self.handlers = handlers
    }

    func outcome(for envelope: WakeEnvelope) async -> WakeAckOutcome {
        guard let handler = handlers[envelope.topic] else { return .noHandler }
        do {
            try await handler(envelope)
            return .handled
        } catch {
            Logger.warn("Wake handler for \(envelope.topic) failed: \(error)", context: "Wake")
            return .failed
        }
    }

    /// Alert wakes reach the notification extension, which must not start the node. The OS shows the alert's text, so
    /// showing it is all the self-test needs.
    static let notificationExtension = WakeHandlerRegistry([
        WakeTopics.test: { _ in },
    ])
}

enum WakeReceipt: Equatable {
    case notAWake
    /// No credentials or no registration to decrypt with and acknowledge to.
    case notRegistered
    case undecryptable
    /// The OS already showed the fallback alert. It has nothing to decrypt or acknowledge.
    case fallback(topic: String)
    /// A v0 envelope, which has no id and no acknowledgement.
    case legacy(topic: String)
    case duplicate(id: String)
    case expired(id: String)
    case acknowledged(id: String, topic: String, outcome: WakeAckOutcome, isDelivered: Bool)
}

/// Decrypts a pushed wake, takes it on once across the app and the extension, drops it past its deadline, does its work
/// and acknowledges it.
struct WakeReceiver {
    typealias Decrypt = (_ pushJson: String, _ secretKeyHex: String) async throws -> WakeEnvelope
    typealias Acknowledge = (_ gatewayUrl: String, _ deviceSecret: String, _ wakeId: String, _ outcome: WakeAckOutcome) async throws -> Void

    let handlers: WakeHandlerRegistry
    var seenStore = WakeSeenStore()
    var loadCredentials: () throws -> WakeCredentials? = WakeStorage.loadCredentials
    var loadRegistration: () throws -> WakeRegistrationRecord = WakeStorage.loadRegistration
    var decrypt: Decrypt = WakePush.decrypt
    var acknowledge: Acknowledge = { gatewayUrl, deviceSecret, wakeId, outcome in
        try await ServiceQueue.background(.core, wrapErrors: false) {
            try await wakeAck(gatewayUrl: gatewayUrl, deviceSecret: deviceSecret, wakeId: wakeId, outcome: outcome)
        }
    }

    var now: () -> UInt64 = { WakeTimestamp.now }

    func receive(pushJson: String) async -> WakeReceipt {
        let credentials: WakeCredentials
        let gatewayUrl: String
        do {
            guard let storedCredentials = try loadCredentials(), let registeredGatewayUrl = try loadRegistration().registeredGatewayUrl else {
                return .notRegistered
            }
            credentials = storedCredentials
            gatewayUrl = registeredGatewayUrl
        } catch {
            Logger.warn("Wake credentials unavailable: \(error)", context: "Wake")
            return .notRegistered
        }

        let envelope: WakeEnvelope
        do {
            envelope = try await decrypt(pushJson, credentials.encryptionSecretKey)
        } catch {
            Logger.warn("Dropped a push that does not decrypt: \(error)", context: "Wake")
            return .undecryptable
        }

        if envelope.fallback {
            return .fallback(topic: envelope.topic)
        }
        guard envelope.version >= 1, let id = envelope.id else {
            return .legacy(topic: envelope.topic)
        }
        guard seenStore.claim(id: id, deadline: envelope.deadline, now: now()) else {
            Logger.info("Skipped wake \(id) on \(envelope.topic), already taken on", context: "Wake")
            return .duplicate(id: id)
        }
        if let deadline = envelope.deadline, now() > deadline {
            Logger.info("Dropped wake \(id) on \(envelope.topic), past its deadline", context: "Wake")
            return .expired(id: id)
        }

        let outcome = await handlers.outcome(for: envelope)
        do {
            try await acknowledge(gatewayUrl, credentials.deviceSecret, id, outcome)
            Logger.info("Acknowledged wake \(id) on \(envelope.topic) as \(outcome)", context: "Wake")
            return .acknowledged(id: id, topic: envelope.topic, outcome: outcome, isDelivered: true)
        } catch {
            Logger.warn("Failed to acknowledge wake \(id) on \(envelope.topic): \(error)", context: "Wake")
            return .acknowledged(id: id, topic: envelope.topic, outcome: outcome, isDelivered: false)
        }
    }
}
