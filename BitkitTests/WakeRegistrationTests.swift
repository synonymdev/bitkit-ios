@testable import Bitkit
import BitkitCore
import UserNotifications
import XCTest

final class WakeTimestampTests: XCTestCase {
    func testTheFirstRegistrationUsesTheClock() {
        XCTAssertEqual(WakeTimestamp.next(now: 1000, last: nil), 1000)
    }

    func testTimestampsKeepIncreasingAcrossLaunches() {
        XCTAssertEqual(WakeTimestamp.next(now: 1000, last: 1000), 1001, "A relaunch within the same second")
        XCTAssertEqual(WakeTimestamp.next(now: 1000, last: 1500), 1501, "A clock that stepped back")
        XCTAssertEqual(WakeTimestamp.next(now: 2000, last: 1500), 2000)
    }

    func testAStaleTimestampIsSignedAgainWithTheGatewaysClock() {
        XCTAssertEqual(WakeTimestamp.retry(serverTime: 1000, last: nil), 1000)
        XCTAssertEqual(WakeTimestamp.retry(serverTime: 1000, last: 900), 1000)
        XCTAssertEqual(WakeTimestamp.retry(serverTime: 1000, last: 1200), 1201, "A registration the gateway may hold stays older")
        XCTAssertEqual(
            WakeTimestamp.retry(serverTime: 1000, last: 1000 + WakeTimestamp.maxSkewSecs),
            1000,
            "One signed with a clock too far ahead was never accepted"
        )
    }

    func testGatewayValuesNearTheTopOfUInt64DoNotTrap() {
        XCTAssertEqual(WakeTimestamp.saturatingAdd(.max, 1), .max)
        XCTAssertEqual(WakeTimestamp.next(now: 1000, last: .max), .max)
        XCTAssertEqual(WakeTimestamp.retry(serverTime: .max, last: 1000), .max)
        XCTAssertEqual(WakeTimestamp.retry(serverTime: .max - 10, last: .max - 5), .max - 4)
    }
}

final class WakeRegistrationPolicyTests: XCTestCase {
    func testRegistersOnlyWithNotificationsAuthorizedAndOn() {
        XCTAssertTrue(WakeRegistrationPolicy.allowsRegistration(authorizationStatus: .authorized, notificationsEnabled: true, isE2E: false))
        XCTAssertFalse(WakeRegistrationPolicy.allowsRegistration(authorizationStatus: .authorized, notificationsEnabled: false, isE2E: false))

        for status: UNAuthorizationStatus in [.notDetermined, .denied, .provisional, .ephemeral] {
            XCTAssertFalse(
                WakeRegistrationPolicy.allowsRegistration(authorizationStatus: status, notificationsEnabled: true, isE2E: false),
                "\(status.rawValue)"
            )
        }
    }

    func testE2EBuildsNeverRegister() {
        XCTAssertFalse(WakeRegistrationPolicy.allowsRegistration(authorizationStatus: .authorized, notificationsEnabled: true, isE2E: true))
    }

    func testWakesAreOffWithoutAGateway() {
        // Unit tests run without WAKE_GATEWAY_URL, like every build but a debug one given it.
        XCTAssertNil(Env.wakeGatewayUrl)
    }

    @MainActor
    func testRegistrationDoesNothingWithoutAGateway() async {
        let inputs = WakeRegistrationInputs(
            isNodeReady: true, pushToken: "00ff", authorizationStatus: .authorized, notificationsEnabled: true, pubkyPublicKey: nil
        )

        let result = await WakeManager.shared.registerIfAllowed(inputs)

        XCTAssertEqual(result, .notConfigured)
    }
}

private let pubkyZ32 = "47cz1q7hnqtedgwnxt5k5pz5in1ji5oyx7r9fwr3fsc5ojppftry"
private let otherPubkyZ32 = "8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo"
private let pubkySecret = String(repeating: "ab", count: 32)

final class WakeIdentityResolverTests: XCTestCase {
    private struct ReadFailed: Error {}

    func testAWalletWithoutAProfileRegistersLightningOnly() {
        let selection = WakeIdentityResolver.select(
            profilePublicKey: nil,
            hasStoredIdentity: { false },
            readSecretKeyHex: { XCTFail("No key is read or derived without a profile"); return pubkySecret },
            derivePublicKey: { _ in XCTFail("No key is derived without a profile"); return pubkyZ32 }
        )

        XCTAssertEqual(selection, .lightningOnly)
    }

    func testAProfileStillLoadingSkipsTheAttempt() {
        XCTAssertEqual(select(profilePublicKey: nil, hasStoredIdentity: { true }), .skip)
        XCTAssertEqual(select(profilePublicKey: nil, hasStoredIdentity: { throw ReadFailed() }), .skip)
    }

    func testALocalOrRingIdentityAddsPubky() {
        for profileKey in ["pubky\(pubkyZ32)", pubkyZ32] {
            for derived in ["pubky\(pubkyZ32)", pubkyZ32] {
                XCTAssertEqual(
                    select(profilePublicKey: profileKey, derivedPublicKey: derived),
                    .lightningAndPubky(publicKeyZ32: pubkyZ32, secretKeyHex: pubkySecret),
                    "Core wants the 52 bare characters, without Bitkit's pubky prefix"
                )
            }
        }
    }

    func testASessionWithoutALocalKeyRegistersLightningOnly() {
        XCTAssertEqual(select(profilePublicKey: "pubky\(pubkyZ32)", secretKeyHex: nil), .lightningOnly)
        XCTAssertEqual(select(profilePublicKey: "pubky\(pubkyZ32)", secretKeyHex: ""), .lightningOnly)
    }

    func testAKeyThatCannotBeReadSkipsTheAttempt() {
        let selection = WakeIdentityResolver.select(
            profilePublicKey: "pubky\(pubkyZ32)",
            hasStoredIdentity: { true },
            readSecretKeyHex: { throw ReadFailed() },
            derivePublicKey: { _ in pubkyZ32 }
        )

        XCTAssertEqual(selection, .skip, "Registering ln: alone would drop pk: and its grants")
    }

    func testAKeyThatCannotBeDerivedSkipsTheAttempt() {
        let selection = WakeIdentityResolver.select(
            profilePublicKey: "pubky\(pubkyZ32)",
            hasStoredIdentity: { true },
            readSecretKeyHex: { pubkySecret },
            derivePublicKey: { _ in throw ReadFailed() }
        )

        XCTAssertEqual(selection, .skip)
    }

    func testAKeyForAnotherPubkyIsNotUsed() {
        XCTAssertEqual(select(profilePublicKey: "pubky\(pubkyZ32)", derivedPublicKey: otherPubkyZ32), .lightningOnly)
    }

    func testIdentitiesAreCanonical() {
        XCTAssertEqual(
            WakeIdentityResolver.identities(nodeId: "02ABCDEF", selection: .lightningOnly),
            ["ln:02abcdef"]
        )
        XCTAssertEqual(
            WakeIdentityResolver.identities(
                nodeId: "02abcdef",
                selection: .lightningAndPubky(publicKeyZ32: pubkyZ32, secretKeyHex: pubkySecret)
            ),
            ["ln:02abcdef", "pk:\(pubkyZ32)"]
        )
    }

    private func select(
        profilePublicKey: String?,
        hasStoredIdentity: @escaping () throws -> Bool = { true },
        secretKeyHex: String? = pubkySecret,
        derivedPublicKey: String = pubkyZ32
    ) -> WakeIdentitySelection {
        WakeIdentityResolver.select(
            profilePublicKey: profilePublicKey,
            hasStoredIdentity: hasStoredIdentity,
            readSecretKeyHex: { secretKeyHex },
            derivePublicKey: { _ in derivedPublicKey }
        )
    }
}

final class WakeStorageTests: XCTestCase {
    override func setUpWithError() throws {
        try Keychain.delete(key: .wakeCredentials)
        try Keychain.delete(key: .wakeRegistration)
    }

    override func tearDownWithError() throws {
        try Keychain.delete(key: .wakeCredentials)
        try Keychain.delete(key: .wakeRegistration)
    }

    func testCredentialsAreMadeOnceAndReused() throws {
        XCTAssertNil(try WakeStorage.loadCredentials())

        let created = try WakeStorage.loadOrCreateCredentials()
        let reused = try WakeStorage.loadOrCreateCredentials()

        XCTAssertEqual(created, reused)
        XCTAssertEqual(try WakeStorage.loadCredentials(), created)
        XCTAssertEqual(created.installId.count, 22)
        XCTAssertEqual(created.encryptionPublicKey.count, 66)
        XCTAssertEqual(created.encryptionSecretKey.count, 64)
        XCTAssertTrue(created.deviceSecret.hasPrefix("wkd_"))
        XCTAssertEqual(created.deviceSecretSha256.count, 64)
    }

    func testTheRegistrationRecordKeepsTheLastTimestamp() throws {
        XCTAssertEqual(try WakeStorage.loadRegistration(), WakeRegistrationRecord())

        let device = WakeRegisteredDevice(
            gatewayUrl: "http://127.0.0.1:9010",
            content: WakeRegistrationContent(
                audience: "wake.localhost", environment: "sandbox", pushToken: "00ff", encryptionPublicKey: "02",
                identities: ["pk:b", "ln:a", "pk:b"], topics: ["swap.*", "paykit.*"]
            )
        )
        try WakeStorage.saveRegistration(WakeRegistrationRecord(lastTimestamp: 1_790_000_000, device: device))
        var record = try WakeStorage.loadRegistration()
        XCTAssertEqual(record.lastTimestamp, 1_790_000_000)
        XCTAssertEqual(record.device?.content.identities, ["ln:a", "pk:b"])
        XCTAssertEqual(record.device?.content.topics, ["paykit.*", "swap.*"])

        record.device = nil
        try WakeStorage.saveRegistration(record)
        XCTAssertEqual(try WakeStorage.loadRegistration(), WakeRegistrationRecord(lastTimestamp: 1_790_000_000, device: nil))
    }

    func testRegistrationContentIgnoresOrder() {
        let content = { (identities: [String], topics: [String]) in
            WakeRegistrationContent(
                audience: "wake.localhost", environment: "sandbox", pushToken: "00ff", encryptionPublicKey: "02",
                identities: identities, topics: topics
            )
        }

        XCTAssertEqual(content(["ln:a", "pk:b"], ["paykit.*", "swap.*"]), content(["pk:b", "ln:a"], ["swap.*", "paykit.*"]))
        XCTAssertNotEqual(content(["ln:a", "pk:b"], ["paykit.*"]), content(["ln:a"], ["paykit.*"]))
    }
}

final class WakeRegistrarTests: XCTestCase {
    private static let now: UInt64 = 1_790_000_000
    private static let lightning = "ln:023c72addb4fdf09af94f0c94d7fe92a386a7e70cf8a1d85916386bb2535c7b1b1"
    private static let pushToken = "00fc13adff785122b4ad28809a3420982341241421348097878e577c991de8f0"

    private var record = WakeRegistrationRecord()
    private var sent: [WakeRegistrationRequest] = []
    private var serverInfoCalls = 0
    private var credentials: WakeCredentials!

    override func setUpWithError() throws {
        credentials = try WakeCredentials.generate()
    }

    func testTheFirstRegistrationSignsTheGatewaysAudienceAtTheDeviceClock() async throws {
        let outcome = try await register()

        XCTAssertEqual(outcome, .registered(Self.registration))
        let request = try XCTUnwrap(sent.first)
        XCTAssertEqual(request.timestamp, Self.now)
        XCTAssertEqual(request.audience, "wake.localhost")
        XCTAssertEqual(request.environment, .sandbox, "Debug builds take their token from the APNs sandbox")
        XCTAssertEqual(request.pushToken, Self.pushToken)
        XCTAssertEqual(request.topics, ["paykit.*", "swap.*"])
        XCTAssertTrue(request.message.contains("\naud:wake.localhost\n"))
        XCTAssertEqual(record.lastTimestamp, Self.now)
        XCTAssertEqual(record.device?.gatewayUrl, "http://127.0.0.1:9010")
        XCTAssertEqual(record.device?.content.identities, [Self.lightning])
    }

    func testAnUnchangedRegistrationIsNotSentAgain() async throws {
        _ = try await register()

        let outcome = try await register()

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(serverInfoCalls, 1, "Nothing changed, so the gateway is not asked")
    }

    func testAForcedRegistrationIsSentAgainWithALaterTimestamp() async throws {
        _ = try await register()

        _ = try await register(force: true)

        XCTAssertEqual(sent.map(\.timestamp), [Self.now, Self.now + 1])
    }

    func testANewTokenWithinTheSameSecondRegistersWithALaterTimestamp() async throws {
        _ = try await register()

        let outcome = try await register(pushToken: String(repeating: "ab", count: 32))

        XCTAssertEqual(outcome, .registered(Self.registration))
        XCTAssertEqual(sent.map(\.timestamp), [Self.now, Self.now + 1], "An equal timestamp with other content is a 409")
        XCTAssertEqual(record.device?.content.pushToken, String(repeating: "ab", count: 32))
    }

    func testAStaleTimestampIsSignedAgainOnceWithTheGatewaysClock() async throws {
        let serverTime = Self.now + 5000
        var attempts = 0

        let outcome = try await register(send: { request in
            attempts += 1
            guard attempts > 1 else {
                throw WakeError.GatewayRejected(status: 401, code: "stale_timestamp", detail: "", serverTime: serverTime, retryAfterSecs: nil)
            }
            return request
        })

        XCTAssertEqual(outcome, .registered(Self.registration))
        XCTAssertEqual(sent.map(\.timestamp), [Self.now, serverTime])
        XCTAssertEqual(record.lastTimestamp, serverTime)
    }

    func testAStaleTimestampIsNotRetriedTwice() async throws {
        let stale = WakeError.GatewayRejected(status: 401, code: "stale_timestamp", detail: "", serverTime: Self.now + 5000, retryAfterSecs: nil)

        do {
            _ = try await register(send: { _ in throw stale })
            XCTFail("Registered")
        } catch {
            XCTAssertEqual(error as? WakeError, stale)
        }
        XCTAssertEqual(sent.count, 2)
        XCTAssertNil(record.device)
    }

    func testAnImplausibleGatewayClockIsNeitherSignedNorKept() async throws {
        let stale = WakeError.GatewayRejected(status: 401, code: "stale_timestamp", detail: "", serverTime: .max, retryAfterSecs: nil)

        do {
            _ = try await register(send: { _ in throw stale })
            XCTFail("Registered")
        } catch {
            XCTAssertEqual(error as? WakeError, stale)
        }
        XCTAssertEqual(sent.map(\.timestamp), [Self.now])
        XCTAssertEqual(record.lastTimestamp, Self.now)
    }

    func testATimestampIsKeptWhenTheAnswerIsLost() async throws {
        do {
            _ = try await register(send: { _ in throw WakeError.RequestFailed(reason: "connection reset") })
            XCTFail("Registered")
        } catch {}

        XCTAssertEqual(record.lastTimestamp, Self.now, "The gateway may have stored it")
        XCTAssertNil(record.device)

        _ = try await register()
        XCTAssertEqual(sent.map(\.timestamp), [Self.now, Self.now + 1])
    }

    func testAnUpdateWhoseAnswerIsLostIsNotTakenAsTheOldRegistration() async throws {
        _ = try await register()
        do {
            _ = try await register(identities: [Self.lightning, Self.pubky], send: { _ in
                throw WakeError.RequestFailed(reason: "connection reset")
            })
            XCTFail("Registered")
        } catch {}
        XCTAssertNil(record.device, "The gateway may hold the update")

        let outcome = try await register()

        XCTAssertEqual(outcome, .registered(Self.registration), "Back to ln only is sent, not skipped as unchanged")
        XCTAssertEqual(sent.map(\.timestamp), [Self.now, Self.now + 1, Self.now + 2])
        XCTAssertEqual(record.device?.content.identities, [Self.lightning])
    }

    // MARK: - Helpers

    private static let pubky = "pk:47cz1q7hnqtedgwnxt5k5pz5in1ji5oyx7r9fwr3fsc5ojppftry"

    private static let registration = WakeRegistration(
        deviceId: "device", identities: [lightning], topics: ["paykit.*", "swap.*"], unknownTopics: [], serverTime: now
    )

    private func register(
        pushToken: String = WakeRegistrarTests.pushToken,
        identities: [String] = [WakeRegistrarTests.lightning],
        force: Bool = false,
        send: ((WakeRegistrationRequest) throws -> WakeRegistrationRequest)? = nil
    ) async throws -> WakeRegistrar.Outcome {
        var registrar = WakeRegistrar(gatewayUrl: "http://127.0.0.1:9010")
        registrar.serverInfo = { _ in
            self.serverInfoCalls += 1
            return WakeServerInfo(audience: "wake.localhost", serverTime: Self.now, version: "0.1.0")
        }
        registrar.loadRegistration = { self.record }
        registrar.saveRegistration = { self.record = $0 }
        registrar.now = { Self.now }
        registrar.send = { _, request, _ in
            self.sent.append(request)
            _ = try send?(request)
            return Self.registration
        }
        return try await registrar.register(
            credentials: credentials,
            pushToken: pushToken,
            identities: identities,
            force: force,
            sign: { _ in [WakeIdentityProof(identity: Self.lightning, signature: "signature")] }
        )
    }
}
