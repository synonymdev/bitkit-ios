@testable import Bitkit
import BitkitCore
import UIKit
import XCTest

/// The push shapes in `Fixtures/wake-pushes.json` are bitkit-core's `src/modules/wake/test_vectors/pushes.json`, copied
/// byte for byte from the wake repository.
private struct WakePushVectors: Decodable {
    struct Case: Decodable {
        let name: String
        let provider: String
        let body: String
        let deviceSecretKey: String?
        let plaintext: String?
    }

    let cases: [Case]

    static func load() throws -> WakePushVectors {
        let bundle = Bundle(for: WakePushDecryptionTests.self)
        let bundledURL = bundle.url(forResource: "wake-pushes", withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "wake-pushes", withExtension: "json")
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/wake-pushes.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(WakePushVectors.self, from: Data(contentsOf: bundledURL ?? sourceURL))
    }

    func apns(_ name: String) throws -> Case {
        try XCTUnwrap(cases.first { $0.provider == "apns" && $0.name == name }, "No APNs vector \(name)")
    }
}

private extension WakePushVectors.Case {
    /// The body as iOS hands it to the app: a dictionary, not the JSON the gateway sent.
    var userInfo: [AnyHashable: Any] {
        get throws {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [AnyHashable: Any])
        }
    }

    var pushJson: String {
        get throws {
            try XCTUnwrap(WakePush.json(from: userInfo))
        }
    }

    var plaintextObject: [String: Any] {
        get throws {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(plaintext).utf8)) as? [String: Any])
        }
    }
}

final class WakePushDecryptionTests: XCTestCase {
    func testEveryApnsShapeDecryptsToItsPlaintext() async throws {
        let vectors = try WakePushVectors.load()
        let apnsCases = vectors.cases.filter { $0.provider == "apns" && $0.deviceSecretKey != nil }
        XCTAssertEqual(apnsCases.count, 5)

        for vector in apnsCases {
            let envelope = try await WakePush.decrypt(pushJson: vector.pushJson, secretKeyHex: XCTUnwrap(vector.deviceSecretKey))
            let plaintext = try vector.plaintextObject

            XCTAssertFalse(envelope.fallback, vector.name)
            if let version = plaintext["v"] as? Int {
                XCTAssertEqual(Int(envelope.version), version, vector.name)
                XCTAssertEqual(envelope.id, plaintext["id"] as? String, vector.name)
                XCTAssertEqual(envelope.topic, plaintext["topic"] as? String, vector.name)
                XCTAssertEqual(envelope.urgency, plaintext["urgency"] as? String, vector.name)
                XCTAssertEqual(envelope.deadline, (plaintext["deadline"] as? NSNumber)?.uint64Value, vector.name)
                try assertPayload(envelope.payloadJson, equals: plaintext["payload"], vector.name)
            } else {
                XCTAssertEqual(envelope.version, 0, vector.name)
                XCTAssertNil(envelope.id, "A v0 envelope has nothing to acknowledge")
                XCTAssertEqual(envelope.topic, "\(plaintext["source"] ?? "").\(plaintext["type"] ?? "")", vector.name)
                XCTAssertEqual(envelope.createdAt, plaintext["createdAt"] as? String, vector.name)
            }
        }
    }

    func testFallbackAlertIsRecognisedWithoutTheKey() async throws {
        let vector = try WakePushVectors.load().apns("apns_fallback")

        let envelope = try await WakePush.decrypt(pushJson: vector.pushJson, secretKeyHex: String(repeating: "11", count: 32))

        XCTAssertTrue(envelope.fallback)
        XCTAssertEqual(envelope.id, "01a0c450-6c00-7000-8000-000000000001")
        XCTAssertEqual(envelope.topic, "blocktank.incomingHtlc")
    }

    func testAPushEncryptedToAnotherKeyDoesNotDecrypt() async throws {
        let vector = try WakePushVectors.load().apns("apns_v1_background")

        do {
            _ = try await WakePush.decrypt(pushJson: vector.pushJson, secretKeyHex: String(repeating: "11", count: 32))
            XCTFail("Decrypted with the wrong key")
        } catch let error as WakeError {
            guard case .DecryptionFailed = error else { return XCTFail("Unexpected \(error)") }
        }
    }

    func testPushesWithoutAWakeAreNotHandedToCore() {
        XCTAssertNil(WakePush.json(from: [:]))
        XCTAssertNil(WakePush.json(from: ["aps": ["alert": ["title": "Hi", "body": "There"]]]))
        XCTAssertNil(WakePush.json(from: ["bitkit_action": "paykit_subscription_due"]))
    }

    func testFallbackAlertIsShownInTheForeground() throws {
        let userInfo = try WakePushVectors.load().apns("apns_fallback").userInfo

        XCTAssertEqual(AppDelegate.foregroundPresentationOptions(for: userInfo), [.banner, .badge, .sound])
    }

    private func assertPayload(_ payloadJson: String?, equals expected: Any?, _ name: String) throws {
        guard let expected, !(expected is NSNull) else {
            XCTAssertNil(payloadJson, name)
            return
        }
        let payload = try JSONSerialization.jsonObject(with: Data(XCTUnwrap(payloadJson, name).utf8))
        XCTAssertEqual(payload as? NSDictionary, expected as? NSDictionary, name)
    }
}

final class WakeReceiverTests: XCTestCase {
    private static let gatewayUrl = "https://wake.example"
    private static let deviceSecret = "wkd_device_secret_for_tests"
    private static let backgroundWakeId = "01a0c450-6c00-7000-8000-000000000001"
    /// `apns_v1_background` is due at 1790000060.
    private static let beforeDeadline: UInt64 = 1_790_000_000

    private var storeDirectory: URL!

    override func setUpWithError() throws {
        storeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("wake-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeDirectory)
    }

    func testABackgroundWakeIsHandledAndAcknowledged() async throws {
        let acks = AckRecorder()
        var handled: [String] = []
        let receiver = try makeReceiver(
            handlers: WakeHandlerRegistry(["blocktank.incomingHtlc": { handled.append($0.topic) }]),
            acks: acks
        )

        let receipt = try await receiver.receive(pushJson: vector("apns_v1_background").pushJson)

        XCTAssertEqual(receipt, .acknowledged(id: Self.backgroundWakeId, topic: "blocktank.incomingHtlc", outcome: .handled, isDelivered: true))
        XCTAssertEqual(handled, ["blocktank.incomingHtlc"])
        XCTAssertEqual(acks.calls, [
            AckRecorder.Call(gatewayUrl: Self.gatewayUrl, deviceSecret: Self.deviceSecret, wakeId: Self.backgroundWakeId, outcome: .handled),
        ])
    }

    func testAWakeWithoutAHandlerIsAcknowledgedAsNoHandler() async throws {
        let acks = AckRecorder()
        let receiver = try makeReceiver(handlers: .app, acks: acks)

        let receipt = try await receiver.receive(pushJson: vector("apns_v1_background_topic_collapse").pushJson)

        XCTAssertEqual(receipt, .acknowledged(
            id: "01a0c450-6c00-7000-8000-000000000004", topic: "paykit.sync", outcome: .noHandler, isDelivered: true
        ))
        XCTAssertEqual(acks.calls.map(\.outcome), [.noHandler])
    }

    func testAFailedHandlerIsAcknowledgedAsFailed() async throws {
        struct WorkFailed: Error {}
        let acks = AckRecorder()
        let receiver = try makeReceiver(handlers: WakeHandlerRegistry(["blocktank.incomingHtlc": { _ in throw WorkFailed() }]), acks: acks)

        let receipt = try await receiver.receive(pushJson: vector("apns_v1_background").pushJson)

        XCTAssertEqual(receipt, .acknowledged(id: Self.backgroundWakeId, topic: "blocktank.incomingHtlc", outcome: .failed, isDelivered: true))
        XCTAssertEqual(acks.calls.map(\.outcome), [.failed])
    }

    func testTheSameWakeIsHandledOnceAcrossTheAppAndTheExtension() async throws {
        let acks = AckRecorder()
        var handledCount = 0
        let handlers = WakeHandlerRegistry(["blocktank.incomingHtlc": { _ in handledCount += 1 }])
        // Two receivers with their own store objects on one directory, as the two processes have.
        let app = try makeReceiver(handlers: handlers, acks: acks, seenStore: WakeSeenStore(directory: storeDirectory))
        let notificationExtension = try makeReceiver(handlers: handlers, acks: acks, seenStore: WakeSeenStore(directory: storeDirectory))
        let push = try vector("apns_v1_background").pushJson

        let first = await notificationExtension.receive(pushJson: push)
        let second = await app.receive(pushJson: push)
        let third = await notificationExtension.receive(pushJson: push)

        XCTAssertEqual(first, .acknowledged(id: Self.backgroundWakeId, topic: "blocktank.incomingHtlc", outcome: .handled, isDelivered: true))
        XCTAssertEqual(second, .duplicate(id: Self.backgroundWakeId))
        XCTAssertEqual(third, .duplicate(id: Self.backgroundWakeId))
        XCTAssertEqual(handledCount, 1)
        XCTAssertEqual(acks.calls.count, 1)
    }

    func testAWakePastItsDeadlineIsDroppedWithoutAnAck() async throws {
        let acks = AckRecorder()
        var handledCount = 0
        var receiver = try makeReceiver(handlers: WakeHandlerRegistry(["blocktank.incomingHtlc": { _ in handledCount += 1 }]), acks: acks)
        receiver.now = { 1_790_000_061 }

        let receipt = try await receiver.receive(pushJson: vector("apns_v1_background").pushJson)

        XCTAssertEqual(receipt, .expired(id: Self.backgroundWakeId))
        XCTAssertEqual(handledCount, 0)
        XCTAssertTrue(acks.calls.isEmpty)
    }

    func testAWakeAtItsDeadlineIsStillHandled() async throws {
        let acks = AckRecorder()
        var receiver = try makeReceiver(handlers: .app, acks: acks)
        receiver.now = { 1_790_000_060 }

        let receipt = try await receiver.receive(pushJson: vector("apns_v1_background").pushJson)

        XCTAssertEqual(receipt, .acknowledged(id: Self.backgroundWakeId, topic: "blocktank.incomingHtlc", outcome: .noHandler, isDelivered: true))
    }

    func testFallbackAndLegacyPushesAreNotAcknowledged() async throws {
        let acks = AckRecorder()
        var receiver = try makeReceiver(handlers: .app, acks: acks)

        let fallback = try await receiver.receive(pushJson: vector("apns_fallback").pushJson)
        receiver.loadCredentials = { Self.credentials(secretKey: String(repeating: "22", count: 32)) }
        let legacy = try await receiver.receive(pushJson: vector("apns_v0").pushJson)

        XCTAssertEqual(fallback, .fallback(topic: "blocktank.incomingHtlc"))
        XCTAssertEqual(legacy, .legacy(topic: "blocktank.incomingHtlc"))
        XCTAssertTrue(acks.calls.isEmpty)
    }

    func testAnUnregisteredInstallDoesNotDecrypt() async throws {
        let acks = AckRecorder()
        var decrypted = false
        var receiver = try makeReceiver(handlers: .app, acks: acks)
        receiver.decrypt = { _, _ in
            decrypted = true
            throw WakeError.InvalidInput(reason: "unexpected")
        }
        receiver.loadRegistration = { WakeRegistrationRecord(lastTimestamp: 1_790_000_000, device: nil) }

        let receipt = try await receiver.receive(pushJson: vector("apns_v1_background").pushJson)

        XCTAssertEqual(receipt, .notRegistered)
        XCTAssertFalse(decrypted)
        XCTAssertTrue(acks.calls.isEmpty)
    }

    func testAWakeForARegistrationWhoseAnswerWasLostIsAcknowledged() async throws {
        let acks = AckRecorder()
        var receiver = try makeReceiver(handlers: .app, acks: acks)
        receiver.loadRegistration = { WakeRegistrationRecord(lastTimestamp: 1_790_000_000, device: nil, sentToGatewayUrl: Self.gatewayUrl) }

        let receipt = try await receiver.receive(pushJson: vector("apns_v1_background").pushJson)

        XCTAssertEqual(receipt, .acknowledged(id: Self.backgroundWakeId, topic: "blocktank.incomingHtlc", outcome: .noHandler, isDelivered: true))
        XCTAssertEqual(acks.calls.map(\.gatewayUrl), [Self.gatewayUrl])
    }

    func testAPushForAnotherKeyIsDropped() async throws {
        let acks = AckRecorder()
        var receiver = try makeReceiver(handlers: .app, acks: acks)
        receiver.loadCredentials = { Self.credentials(secretKey: String(repeating: "11", count: 32)) }

        let receipt = try await receiver.receive(pushJson: vector("apns_v1_background").pushJson)

        XCTAssertEqual(receipt, .undecryptable)
        XCTAssertTrue(acks.calls.isEmpty)
    }

    func testAnAckThatDoesNotReachTheGatewayIsReported() async throws {
        let acks = AckRecorder(failure: WakeError.RequestFailed(reason: "offline"))
        let receiver = try makeReceiver(handlers: .app, acks: acks)

        let receipt = try await receiver.receive(pushJson: vector("apns_v1_background").pushJson)

        XCTAssertEqual(receipt, .acknowledged(id: Self.backgroundWakeId, topic: "blocktank.incomingHtlc", outcome: .noHandler, isDelivered: false))
    }

    // MARK: - Ack outcomes

    func testTheExtensionHandlesTheSelfTestAndNothingElse() async {
        let registry = WakeHandlerRegistry.notificationExtension

        let selfTest = await registry.outcome(for: Self.envelope(topic: "wake.test"))
        let other = await registry.outcome(for: Self.envelope(topic: "blocktank.mutualClose"))

        XCTAssertEqual(selfTest, .handled, "The OS shows the self-test alert, which is all it needs")
        XCTAssertEqual(other, .noHandler)
    }

    func testTheAppHasNoBackgroundHandlersYet() async {
        let paykitSync = await WakeHandlerRegistry.app.outcome(for: Self.envelope(topic: "paykit.sync"))
        let swapClaimable = await WakeHandlerRegistry.app.outcome(for: Self.envelope(topic: "swap.claimable"))

        XCTAssertEqual(paykitSync, .noHandler)
        XCTAssertEqual(swapClaimable, .noHandler)
    }

    func testBackgroundFetchResultFollowsTheAck() {
        func receipt(_ outcome: WakeAckOutcome) -> WakeReceipt {
            .acknowledged(id: "id", topic: "swap.claimable", outcome: outcome, isDelivered: true)
        }

        XCTAssertEqual(WakeManager.fetchResult(for: receipt(.handled)), .newData)
        XCTAssertEqual(WakeManager.fetchResult(for: receipt(.noHandler)), .noData)
        XCTAssertEqual(WakeManager.fetchResult(for: receipt(.failed)), .failed)
        XCTAssertEqual(WakeManager.fetchResult(for: .duplicate(id: "id")), .noData)
        XCTAssertEqual(WakeManager.fetchResult(for: .expired(id: "id")), .noData)
        XCTAssertEqual(WakeManager.fetchResult(for: .notAWake), .noData)
        XCTAssertEqual(WakeManager.fetchResult(for: nil), .failed, "Work that ran out of time")
    }

    // MARK: - Helpers

    private func vector(_ name: String) throws -> WakePushVectors.Case {
        try WakePushVectors.load().apns(name)
    }

    private func makeReceiver(handlers: WakeHandlerRegistry, acks: AckRecorder, seenStore: WakeSeenStore? = nil) throws -> WakeReceiver {
        var receiver = WakeReceiver(handlers: handlers)
        receiver.seenStore = seenStore ?? WakeSeenStore(directory: storeDirectory)
        receiver.loadCredentials = { Self.credentials(secretKey: String(repeating: "55", count: 32)) }
        receiver.loadRegistration = {
            WakeRegistrationRecord(
                lastTimestamp: 1_790_000_000,
                device: WakeRegisteredDevice(
                    gatewayUrl: Self.gatewayUrl,
                    content: WakeRegistrationContent(
                        audience: "wake.example", environment: "sandbox", pushToken: "00", encryptionPublicKey: "02",
                        identities: ["ln:02"], topics: WakeConfig.topics
                    )
                )
            )
        }
        receiver.acknowledge = { try await acks.record($0, $1, $2, $3) }
        receiver.now = { Self.beforeDeadline }
        return receiver
    }

    private static func credentials(secretKey: String) -> WakeCredentials {
        WakeCredentials(
            installId: "AAAAAAAAAAAAAAAAAAAAAA",
            encryptionPublicKey: "02",
            encryptionSecretKey: secretKey,
            deviceSecret: deviceSecret,
            deviceSecretSha256: "00"
        )
    }

    private static func envelope(topic: String) -> WakeEnvelope {
        WakeEnvelope(
            version: 1, id: "01a0c450-6c00-7000-8000-0000000000aa", topic: topic, urgency: "alert", deadline: 1_790_000_300,
            payloadJson: nil, createdAt: nil, fallback: false
        )
    }
}

private final class AckRecorder {
    struct Call: Equatable {
        let gatewayUrl: String
        let deviceSecret: String
        let wakeId: String
        let outcome: WakeAckOutcome
    }

    private(set) var calls: [Call] = []
    private let failure: Error?

    init(failure: Error? = nil) {
        self.failure = failure
    }

    func record(_ gatewayUrl: String, _ deviceSecret: String, _ wakeId: String, _ outcome: WakeAckOutcome) async throws {
        calls.append(Call(gatewayUrl: gatewayUrl, deviceSecret: deviceSecret, wakeId: wakeId, outcome: outcome))
        if let failure {
            throw failure
        }
    }
}

final class WakeSeenStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wake-seen-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAnIdIsClaimedOnceAcrossStoresSharingTheAppGroup() {
        let app = WakeSeenStore(directory: directory)
        let notificationExtension = WakeSeenStore(directory: directory)

        XCTAssertTrue(app.claim(id: "a", deadline: 2000, now: 1000))
        XCTAssertFalse(notificationExtension.claim(id: "a", deadline: 2000, now: 1000))
        XCTAssertFalse(app.claim(id: "a", deadline: 2000, now: 1500))
        XCTAssertTrue(notificationExtension.claim(id: "b", deadline: 2000, now: 1000))
    }

    func testAnIdIsForgottenAnHourAfterItsDeadline() {
        let store = WakeSeenStore(directory: directory)

        XCTAssertTrue(store.claim(id: "a", deadline: 2000, now: 1000))
        XCTAssertFalse(store.claim(id: "a", deadline: 2000, now: 2000 + WakeSeenStore.retentionAfterDeadlineSecs - 1))
        XCTAssertTrue(store.claim(id: "a", deadline: 2000, now: 2000 + WakeSeenStore.retentionAfterDeadlineSecs))
    }

    func testTheStoreKeepsTheNewestIds() {
        let store = WakeSeenStore(directory: directory)
        for index in 0 ... WakeSeenStore.maxEntries {
            XCTAssertTrue(store.claim(id: "wake-\(index)", deadline: 10000 + UInt64(index), now: 1000))
        }

        XCTAssertTrue(store.claim(id: "wake-0", deadline: 10000, now: 1000), "The oldest id made room for the newest")
        XCTAssertFalse(store.claim(id: "wake-\(WakeSeenStore.maxEntries)", deadline: 10000, now: 1000))
    }

    func testADeadlineNearTheTopOfUInt64DoesNotTrap() {
        XCTAssertTrue(WakeSeenStore(directory: directory).claim(id: "a", deadline: .max, now: 1000))
        XCTAssertTrue(WakeSeenStore(directory: directory).claim(id: "b", deadline: nil, now: .max))
    }

    func testAnUnusableStoreLetsTheWakeThrough() throws {
        let blocked = directory.appendingPathComponent("file")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: blocked)
        let store = WakeSeenStore(directory: blocked)

        XCTAssertTrue(store.claim(id: "a", deadline: 2000, now: 1000))
        XCTAssertTrue(store.claim(id: "a", deadline: 2000, now: 1000))
    }
}
