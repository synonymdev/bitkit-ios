@testable import Bitkit
import BitkitCore
import XCTest

/// Runs against the wake repository's docker stack, which records pushes in its fake APNs instead of sending them:
///
///     docker compose -f docker/compose.yml --profile dev up -d --build --wait
///     TEST_RUNNER_WAKE_LIVE_GATEWAY_URL=http://127.0.0.1:9010 TEST_RUNNER_WAKE_LIVE_FAKE_PUSH_URL=http://127.0.0.1:9100 \
///         xcodebuild test ... -only-testing:BitkitTests/WakeGatewayLiveTests
///
/// The device registers with `pk:` alone, since a test has no node to sign `ln:` with.
final class WakeGatewayLiveTests: XCTestCase {
    private var gatewayUrl: String!
    private var fakePushUrl: String!

    override func setUpWithError() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let gatewayUrl = environment["WAKE_LIVE_GATEWAY_URL"], let fakePushUrl = environment["WAKE_LIVE_FAKE_PUSH_URL"] else {
            throw XCTSkip("Set WAKE_LIVE_GATEWAY_URL and WAKE_LIVE_FAKE_PUSH_URL to run against a wake gateway")
        }
        self.gatewayUrl = gatewayUrl
        self.fakePushUrl = fakePushUrl
        try Keychain.delete(key: .wakeCredentials)
        try Keychain.delete(key: .wakeRegistration)
    }

    override func tearDownWithError() throws {
        try Keychain.delete(key: .wakeCredentials)
        try Keychain.delete(key: .wakeRegistration)
    }

    @MainActor
    func testRegisterReceiveAcknowledgeAndUnregister() async throws {
        let credentials = try WakeStorage.loadOrCreateCredentials()
        let pubkySecret = (0 ..< 32).map { _ in String(format: "%02x", UInt8.random(in: 0 ... 255)) }.joined()
        let pubky = try XCTUnwrap(PubkyPublicKeyFormat.normalized(PubkyService.pubkyPublicKeyFromSecret(secretKeyHex: pubkySecret)))
        let identity = "pk:\(pubky.dropFirst("pubky".count))"
        let sign: WakeRegistrar.Sign = { request in
            try [WakeIdentityProof(identity: identity, signature: wakeSignPubkyProof(secretKeyHex: pubkySecret, message: request.message))]
        }
        let pushToken = (0 ..< 32).map { _ in String(format: "%02x", UInt8.random(in: 0 ... 255)) }.joined()
        let registrar = WakeRegistrar(gatewayUrl: gatewayUrl)

        // Registers, skips the same registration, and registers a new token within the same second without a 409.
        guard case let .registered(first) = try await registrar.register(
            credentials: credentials, pushToken: pushToken, identities: [identity], force: false, sign: sign
        ) else { return XCTFail("Not registered") }
        XCTAssertEqual(first.identities, [identity])
        XCTAssertEqual(first.unknownTopics, [])
        let unchanged = try await registrar.register(
            credentials: credentials, pushToken: pushToken, identities: [identity], force: false, sign: sign
        )
        XCTAssertEqual(unchanged, .unchanged)
        let newToken = (0 ..< 32).map { _ in String(format: "%02x", UInt8.random(in: 0 ... 255)) }.joined()
        let afterTokenChange = try await registrar.register(
            credentials: credentials, pushToken: newToken, identities: [identity], force: false, sign: sign
        )
        XCTAssertNotEqual(afterTokenChange, .unchanged)

        // A device clock an hour ahead is refused as stale and signed again with the gateway's time.
        var skewed = registrar
        skewed.now = { WakeTimestamp.now + 3600 }
        let afterStaleTimestamp = try await skewed.register(
            credentials: credentials, pushToken: pushToken, identities: [identity], force: false, sign: sign
        )
        XCTAssertNotEqual(afterStaleTimestamp, .unchanged)
        let device = try await wakeGetDevice(gatewayUrl: gatewayUrl, deviceSecret: credentials.deviceSecret)
        XCTAssertEqual(device.environment, .sandbox)
        XCTAssertEqual(device.topics, ["paykit.*", "swap.*"])

        // The self-test is an alert: the notification extension decrypts it and acknowledges it handled.
        let testWakeId = try await wakeSendTest(gatewayUrl: gatewayUrl, deviceSecret: credentials.deviceSecret)
        let alert = try await recordedPush(token: pushToken) { $0.contains("\"mutable-content\":1") }
        let seenStore = WakeSeenStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("wake-live-\(UUID().uuidString)"))
        let alertReceipt = await WakeReceiver(handlers: .notificationExtension, seenStore: seenStore).receive(pushJson: alert)
        XCTAssertEqual(alertReceipt, .acknowledged(id: testWakeId, topic: "wake.test", outcome: .handled, isDelivered: true))

        // A peer wake is a background push: the app delegate acknowledges it without a handler, once.
        let grant = try await wakeCreateGrant(
            gatewayUrl: gatewayUrl, deviceSecret: credentials.deviceSecret, recipient: identity, topics: ["paykit.sync"],
            perHour: nil, perDay: nil, expiresInDays: nil
        )
        try await wakeSendPeerWake(gatewayUrl: gatewayUrl, grantToken: grant.token, topic: "paykit.sync")
        let background = try await recordedPush(token: pushToken) { $0.contains("\"content-available\":1") }
        let backgroundReceipt = await WakeReceiver(handlers: .app, seenStore: seenStore).receive(pushJson: background)
        guard case let .acknowledged(backgroundWakeId, "paykit.sync", .noHandler, true) = backgroundReceipt else {
            return XCTFail("Unexpected \(backgroundReceipt)")
        }
        let duplicateReceipt = await WakeReceiver(handlers: .notificationExtension, seenStore: seenStore).receive(pushJson: background)
        XCTAssertEqual(duplicateReceipt, .duplicate(id: backgroundWakeId))
        try await wakeRevokeGrant(gatewayUrl: gatewayUrl, deviceSecret: credentials.deviceSecret, grantId: grant.id)

        // After unregistering, the old device secret is refused.
        await WakeManager.shared.unregister()
        XCTAssertNil(try WakeStorage.loadRegistration().device)
        do {
            _ = try await wakeGetDevice(gatewayUrl: gatewayUrl, deviceSecret: credentials.deviceSecret)
            XCTFail("The unregistered secret still works")
        } catch let WakeError.GatewayRejected(status, _, _, _, _) {
            XCTAssertEqual(status, 401)
        }
    }

    /// The newest push the fake APNs recorded for `token` whose body passes `matches`.
    private func recordedPush(token: String, matching matches: (String) -> Bool) async throws -> String {
        struct NoPushRecorded: Error {}
        struct Recorded: Decodable {
            let seq: UInt64
            let token: String
            let rawBody: String
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let url = try XCTUnwrap(URL(string: "\(fakePushUrl!)/_recorded"))
        for _ in 0 ..< 50 {
            let (data, _) = try await URLSession.shared.data(from: url)
            let pushes = try decoder.decode([Recorded].self, from: data)
            if let push = pushes.filter({ $0.token == token && matches($0.rawBody) }).max(by: { $0.seq < $1.seq }) {
                return push.rawBody
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw NoPushRecorded()
    }
}
