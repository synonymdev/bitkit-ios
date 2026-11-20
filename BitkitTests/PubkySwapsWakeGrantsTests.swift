@testable import Bitkit
import BitkitCore
import XCTest

final class PubkySwapsWakeGrantsTests: XCTestCase {
    private let gatewayUrl = "https://wake.bitkit.to"
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PubkySwapsWakeGrantsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Target

    func testOnlyARegisteredInstallWithNotificationsOnGetsAGrant() {
        let registered = record(identities: ["ln:node", "pk:key"])
        XCTAssertNil(resolve(record: registered, notificationsEnabled: false))
        XCTAssertNil(resolve(record: WakeRegistrationRecord(), notificationsEnabled: true))
        XCTAssertNil(resolve(record: registered, credentials: nil))
        XCTAssertNil(resolve(gatewayUrl: nil, record: registered))
        XCTAssertNil(resolve(gatewayUrl: "https://wake.staging.bitkit.to", record: registered))
        // An update whose answer is outstanding may have moved the install to another gateway.
        var moving = registered
        moving.sentToGatewayUrl = "https://wake.staging.bitkit.to"
        XCTAssertNil(resolve(record: moving))
    }

    func testTheGrantIsForThePubkyIdentityElseTheNode() {
        XCTAssertEqual(resolve(record: record(identities: ["ln:node", "pk:key"]))?.recipient, "pk:key")
        XCTAssertEqual(resolve(record: record(identities: ["ln:node"]))?.recipient, "ln:node")
        XCTAssertEqual(resolve(record: record(identities: ["ln:node"]))?.deviceSecret, "secret")
    }

    func testTheTargetLeavesTheDeviceSecretOutOfItsDescription() {
        let target = SwapWakeGrantTarget(gatewayUrl: gatewayUrl, deviceSecret: "secret", recipient: "pk:key")
        XCTAssertFalse(String(describing: target).contains("secret"))
        XCTAssertFalse(String(reflecting: target).contains("secret"))
    }

    // MARK: - Hand over

    func testNoGrantForAProviderThatSendsNoWakesOrAnUnregisteredInstall() async {
        let calls = RecordedCalls()
        let notTaken = await makeGrants(calls).handOver(swapId: "swap", providerTakesWake: false)
        let notRegistered = await makeGrants(calls, target: nil).handOver(swapId: "swap", providerTakesWake: true)

        XCTAssertEqual(notTaken, .notTaken)
        XCTAssertEqual(notRegistered, .notRegistered)
        let created = await calls.created
        XCTAssertTrue(created.isEmpty)
    }

    func testTheProviderGetsTheGrantsTokenAndExpiry() async {
        let calls = RecordedCalls()
        let result = await makeGrants(calls).handOver(swapId: "swap", providerTakesWake: true)

        XCTAssertEqual(result, .held)
        let created = await calls.created
        XCTAssertEqual(created, [.init(recipient: "pk:key", topics: ["swap.claimable"], expiresInDays: 2)])
        let sent = await calls.sent
        XCTAssertEqual(sent, [.init(swapId: "swap", gatewayUrl: gatewayUrl, token: "wkg_token", expiresAt: 1000)])
        XCTAssertEqual(store.grants["swap"], SwapWakeGrantRecord(grantId: "grant", gatewayUrl: gatewayUrl))
        let revoked = await calls.revoked
        XCTAssertTrue(revoked.isEmpty)
    }

    func testAGrantTheProviderRefusedIsRevoked() async {
        let calls = RecordedCalls(sendError: PubkySwapError.Refused(code: "invalid_request", reason: "refused"))
        let result = await makeGrants(calls).handOver(swapId: "swap", providerTakesWake: true)

        XCTAssertEqual(result, .failed)
        let revoked = await calls.revoked
        XCTAssertEqual(revoked, ["grant"])
        XCTAssertNil(store.grants["swap"])
    }

    func testASwapClaimableAlreadyIsAdvancedAndItsGrantRevoked() async {
        let calls = RecordedCalls(isClaimable: true)
        let result = await makeGrants(calls).handOver(swapId: "swap", providerTakesWake: true)

        XCTAssertEqual(result, .alreadyClaimable)
        let revoked = await calls.revoked
        XCTAssertEqual(revoked, ["grant"])
        let advanced = await calls.advanced
        XCTAssertEqual(advanced, ["swap"])
    }

    func testAFailedGrantLeavesNothingToRevoke() async {
        let calls = RecordedCalls(createError: WakeError.RequestFailed(reason: "offline"))
        let result = await makeGrants(calls).handOver(swapId: "swap", providerTakesWake: true)

        XCTAssertEqual(result, .failed)
        let sent = await calls.sent
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(store.grants.isEmpty)
    }

    func testAGrantForASwapThatEndedMeanwhileIsRevoked() async {
        let calls = RecordedCalls()
        let result = await makeGrants(calls, isUnfinished: false).handOver(swapId: "swap", providerTakesWake: true)

        XCTAssertEqual(result, .failed)
        let revoked = await calls.revoked
        XCTAssertEqual(revoked, ["grant"])
        XCTAssertTrue(store.grants.isEmpty)
    }

    // MARK: - Revoke

    func testAnEndedSwapsGrantIsRevokedOnce() async {
        let calls = RecordedCalls()
        let grants = makeGrants(calls)
        await grants.handOver(swapId: "swap", providerTakesWake: true)

        await grants.revoke(swapId: "swap")
        await grants.revoke(swapId: "swap")
        await grants.revoke(swapId: "other")

        let revoked = await calls.revoked
        XCTAssertEqual(revoked, ["grant"])
        XCTAssertTrue(store.grants.isEmpty)
    }

    func testAFailedRevokeDropsTheGrantAnyway() async {
        let calls = RecordedCalls(revokeError: WakeError.RequestFailed(reason: "offline"))
        let grants = makeGrants(calls)
        await grants.handOver(swapId: "swap", providerTakesWake: true)

        await grants.revoke(swapId: "swap")

        XCTAssertTrue(store.grants.isEmpty)
    }

    func testAWipeForgetsEveryGrant() async {
        let grants = makeGrants(RecordedCalls())
        await grants.handOver(swapId: "swap", providerTakesWake: true)

        await grants.resetForWipe()

        XCTAssertTrue(store.grants.isEmpty)
    }

    // MARK: - Helpers

    private var store: SwapWakeGrantStore {
        SwapWakeGrantStore(defaults: defaults)
    }

    private func record(identities: [String]) -> WakeRegistrationRecord {
        WakeRegistrationRecord(
            lastTimestamp: 1,
            device: WakeRegisteredDevice(
                gatewayUrl: gatewayUrl,
                content: WakeRegistrationContent(
                    audience: "wake.bitkit.to",
                    environment: "sandbox",
                    pushToken: "token",
                    encryptionPublicKey: "key",
                    identities: identities,
                    topics: ["paykit.*", "swap.*"]
                )
            ),
            sentToGatewayUrl: nil
        )
    }

    private func resolve(
        gatewayUrl: String? = "https://wake.bitkit.to",
        record: WakeRegistrationRecord,
        credentials: WakeCredentials? = WakeCredentials(
            installId: "install",
            encryptionPublicKey: "public",
            encryptionSecretKey: "private",
            deviceSecret: "secret",
            deviceSecretSha256: "hash"
        ),
        notificationsEnabled: Bool = true
    ) -> SwapWakeGrantTarget? {
        SwapWakeGrantTarget.resolve(gatewayUrl: gatewayUrl, record: record, credentials: credentials, notificationsEnabled: notificationsEnabled)
    }

    private func makeGrants(
        _ calls: RecordedCalls,
        target: SwapWakeGrantTarget? = SwapWakeGrantTarget(gatewayUrl: "https://wake.bitkit.to", deviceSecret: "secret", recipient: "pk:key"),
        isUnfinished: Bool = true
    ) -> PubkySwapsWakeGrants {
        PubkySwapsWakeGrants(
            store: store,
            calls: PubkySwapsWakeGrants.Calls(
                createGrant: { target, topics, days in try await calls.createGrant(target, topics, days) },
                revokeGrant: { _, _, grantId in try await calls.revokeGrant(grantId) },
                sendCapability: { swapId, gatewayUrl, token, expiresAt in
                    try await calls.sendCapability(swapId, gatewayUrl, token, expiresAt)
                },
                advance: { await calls.advance($0) }
            ),
            target: { target },
            deviceSecret: { "secret" },
            isUnfinished: { _ in isUnfinished }
        )
    }
}

private actor RecordedCalls {
    struct Created: Equatable {
        let recipient: String
        let topics: [String]
        let expiresInDays: UInt32
    }

    struct Sent: Equatable {
        let swapId: String
        let gatewayUrl: String
        let token: String
        let expiresAt: UInt64
    }

    private let createError: Error?
    private let sendError: Error?
    private let revokeError: Error?
    private let isClaimable: Bool
    private(set) var created: [Created] = []
    private(set) var sent: [Sent] = []
    private(set) var revoked: [String] = []
    private(set) var advanced: [String] = []

    init(createError: Error? = nil, sendError: Error? = nil, revokeError: Error? = nil, isClaimable: Bool = false) {
        self.createError = createError
        self.sendError = sendError
        self.revokeError = revokeError
        self.isClaimable = isClaimable
    }

    func createGrant(_ target: SwapWakeGrantTarget, _ topics: [String], _ days: UInt32) throws -> WakeGrant {
        if let createError {
            throw createError
        }
        created.append(Created(recipient: target.recipient, topics: topics, expiresInDays: days))
        return WakeGrant(
            id: "grant",
            token: "wkg_token",
            recipient: target.recipient,
            topics: topics,
            perHour: 4,
            perDay: 20,
            createdAt: 0,
            expiresAt: 1000
        )
    }

    func revokeGrant(_ grantId: String) throws {
        revoked.append(grantId)
        if let revokeError {
            throw revokeError
        }
    }

    func sendCapability(_ swapId: String, _ gatewayUrl: String, _ token: String, _ expiresAt: UInt64) throws -> Bool {
        sent.append(Sent(swapId: swapId, gatewayUrl: gatewayUrl, token: token, expiresAt: expiresAt))
        if let sendError {
            throw sendError
        }
        return isClaimable
    }

    func advance(_ swapId: String) {
        advanced.append(swapId)
    }
}
