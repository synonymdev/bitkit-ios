@testable import Bitkit
import Paykit
import XCTest

final class PrivatePaykitServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Constructing `PrivatePaykitService` and mutating it writes the real cache state, injecting
        // fake contacts and invoices into the user's own and flagging the wallet backup dirty. It also
        // reaches `PrivatePaykitAddressReservationStore`, which persists its own ledger and removes the
        // receive address outright — more keys than are worth enumerating, so snapshot the domain.
        snapshotAppDefaultsDomain()
    }

    func testPrivateMessageDrainKeysRespectLinkStateAndPendingOutbound() {
        let peers: [String: LinkedPeerState] = [
            "idle": .linked, "pending": .linked, "new": .notLinked,
            "linking": .linking, "recovering": .recoveryRequired,
            "blocked": .blocked, "unknown": .unknown,
        ]
        let keys = Set(peers.keys).union(["missing", "missing-pending"])
        let outbound: Set = ["pending", "missing-pending", "blocked", "unknown", "unrelated"]
        for retryMissingPeers in [false, true] {
            let pending = PrivatePaykitService.pendingPrivateMessageDrainKeys(
                keys, linkedPeers: peers, pendingOutbound: outbound, retryMissingPeers: retryMissingPeers
            )
            var expected: Set = ["pending", "missing-pending", "new", "linking", "recovering"]
            if retryMissingPeers { expected.insert("missing") }
            XCTAssertEqual(pending, expected)
        }
    }

    func testNewPeerWakesRetryTimerWithoutInheritingOlderPeerBackoff() async {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        let oldKey = "pubky" + String(repeating: "y", count: 52)
        let newKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let now = Date(timeIntervalSince1970: 100)
        let oldSleep = expectation(description: "Older peer waits ninety seconds")
        let newSleep = expectation(description: "New peer waits only one second")
        let linked = expectation(description: "Explicit peer completes targeted intake")
        var sleepDelays: [UInt64] = []
        var advanced = false
        var priorities: [PaykitSdkOperationLock.Priority] = []
        var peerReads = 0
        var outboundReads = 0
        let service = PrivatePaykitService(messageRetryOperations: .init(
            now: { now },
            sleep: { delay in
                sleepDelays.append(delay)
                if sleepDelays.count == 1 { oldSleep.fulfill() }
                if sleepDelays.count == 2 { newSleep.fulfill() }
                try await Task.sleep(for: .seconds(3600))
            },
            currentPublicKey: { _ in "identity" },
            drain: { priority in
                priorities.append(priority)
                return .init(
                    ensureLink: { key in XCTAssertEqual(key, newKey); advanced = true },
                    pendingOutbound: { outboundReads += 1; return [] },
                    linkedPeers: {
                        peerReads += 1
                        return [self.drainPeer(newKey, state: advanced ? .linked : .linking)]
                    },
                    processPending: { _ in XCTFail("No outbound messages") },
                    receive: { XCTAssertEqual($0, newKey) }
                )
            },
            didLink: { identity, key in
                XCTAssertEqual(identity, "identity")
                XCTAssertEqual(key, newKey)
                linked.fulfill()
            }
        ))
        _ = await service.rememberSavedContacts([oldKey, newKey], replacing: true)
        await service.setTestRetry(.init(nextAttemptAt: now.addingTimeInterval(90), retryIndex: 5), for: oldKey)
        await service.schedulePrivatePaymentRecovery(for: oldKey)
        await fulfillment(of: [oldSleep], timeout: 2)
        await service.schedulePrivatePaymentRecovery(for: newKey)
        await fulfillment(of: [newSleep], timeout: 2)
        XCTAssertEqual(Array(sleepDelays.prefix(2)), [90_000_000_000, 1_000_000_000])
        await service.scheduleExplicitContactLink(publicKey: newKey, identity: "identity")
        await fulfillment(of: [linked], timeout: 2)
        let olderRetry = await service.pendingMessageDrainRetries[oldKey]
        XCTAssertEqual(olderRetry?.nextAttemptAt, now.addingTimeInterval(90))
        XCTAssertEqual(olderRetry?.retryIndex, 5)
        XCTAssertFalse(priorities.isEmpty)
        XCTAssertTrue(priorities.allSatisfy { $0 == .interactive })
        XCTAssertEqual(peerReads, 3)
        XCTAssertEqual(outboundReads, 2)
        await service.invalidateContactPreparation()
    }

    func testExplicitRetryRetiresMissingPeerDuringCooldown() async {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        let key = "pubky" + String(repeating: "y", count: 52)
        let otherKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        for hasPendingOutbound in [false, true] {
            var now = Date(timeIntervalSince1970: 100)
            var handshakes = 0
            var deliveries = 0
            var sleeps = 0
            let settled = expectation(description: "Retry retires or reaches the longest backoff")
            settled.assertForOverFulfill = false
            let (resume, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            let service = PrivatePaykitService(messageRetryOperations: .init(
                now: { now },
                sleep: { delay in
                    sleeps += 1
                    now = now.addingTimeInterval(TimeInterval(delay) / 1_000_000_000)
                    if sleeps == 6 {
                        settled.fulfill()
                        for await _ in resume {}
                    }
                },
                currentPublicKey: { _ in "identity" },
                drain: { _ in
                    .init(
                        ensureLink: { _ in
                            handshakes += 1
                            throw PaykitError.NotFound(code: "not_found", context: "No App Registry")
                        },
                        pendingOutbound: { hasPendingOutbound ? [key, otherKey] : [otherKey] },
                        linkedPeers: { [self.drainPeer(key, state: .notLinked)] },
                        processPending: { _ in deliveries += 1 },
                        receive: { _ in XCTFail("No linked peer") }
                    )
                },
                didLink: { _, _ in XCTFail("Missing peer cannot link") }
            ))
            _ = await service.rememberSavedContacts([key], replacing: true)
            await service.scheduleExplicitContactLink(publicKey: key, identity: "identity")
            let task = await service.pendingMessageDrainRetryTask
            let completion = Task { await task?.value; settled.fulfill() }
            await fulfillment(of: [settled], timeout: 2)
            let retry = await service.pendingMessageDrainRetries[key]
            XCTAssertEqual(retry != nil, hasPendingOutbound)
            XCTAssertEqual(deliveries > 0, hasPendingOutbound)
            XCTAssertEqual(handshakes, 1)
            await service.invalidateContactPreparation()
            continuation.finish()
            await completion.value
        }
    }

    func testMissingPeerRetiresAfterQueuedDeliveryDrains() async {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        let key = "pubky" + String(repeating: "y", count: 52)
        var now = Date(timeIntervalSince1970: 100)
        var handshakes = 0
        var deliveries = 0
        var sleeps = 0
        var hasPendingOutbound = true
        var readFailed = false
        var confirmedEmpty = false
        var failIdentityInspection = false
        var identityInspectionFailed = false
        let settled = expectation(description: "Queued delivery drains and retry retires")
        settled.assertForOverFulfill = false
        let (resume, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let service = PrivatePaykitService(messageRetryOperations: .init(
            now: { now },
            sleep: { delay in
                sleeps += 1
                now = now.addingTimeInterval(TimeInterval(delay) / 1_000_000_000)
                if sleeps == 6 {
                    settled.fulfill()
                    for await _ in resume {}
                }
            },
            currentPublicKey: { _ in
                if failIdentityInspection {
                    failIdentityInspection = false
                    identityInspectionFailed = true
                    throw PaykitError.Transport(code: "offline", context: "Unavailable homeserver")
                }
                return "identity"
            },
            drain: { _ in
                .init(
                    ensureLink: { _ in
                        handshakes += 1
                        failIdentityInspection = true
                        throw PaykitError.NotFound(code: "not_found", context: "No App Registry")
                    },
                    pendingOutbound: {
                        if deliveries == 2, !readFailed {
                            readFailed = true
                            throw PaykitError.Transport(code: "offline", context: "Unavailable homeserver")
                        }
                        if readFailed { confirmedEmpty = !hasPendingOutbound }
                        return hasPendingOutbound ? [key] : []
                    },
                    linkedPeers: { [self.drainPeer(key, state: .notLinked)] },
                    processPending: {
                        XCTAssertEqual($0, key)
                        deliveries += 1
                        if deliveries == 1 {
                            throw PaykitError.Transport(code: "offline", context: "Unavailable homeserver")
                        }
                        hasPendingOutbound = false
                    },
                    receive: { _ in XCTFail("No linked peer") }
                )
            },
            didLink: { _, _ in XCTFail("Missing peer cannot link") }
        ))
        _ = await service.rememberSavedContacts([key], replacing: true)
        await service.scheduleExplicitContactLink(publicKey: key, identity: "identity")
        let task = await service.pendingMessageDrainRetryTask
        let completion = Task { await task?.value; settled.fulfill() }
        await fulfillment(of: [settled], timeout: 2)
        let retry = await service.pendingMessageDrainRetries[key]
        XCTAssertNil(retry)
        XCTAssertEqual(handshakes, 1)
        XCTAssertEqual(deliveries, 2)
        XCTAssertTrue(readFailed)
        XCTAssertTrue(confirmedEmpty)
        XCTAssertTrue(identityInspectionFailed)
        XCTAssertFalse(hasPendingOutbound)
        await service.invalidateContactPreparation()
        continuation.finish()
        await completion.value
    }

    func testExplicitRetrySurvivesTransportCooldown() async {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        let key = "pubky" + String(repeating: "y", count: 52)
        var now = Date(timeIntervalSince1970: 100)
        var handshakes = 0
        var publicationHandshakes = 0
        var sleeps = 0
        var armCooldown: (() async -> Void)?
        let settled = expectation(description: "Retry retires or reaches the expired cooldown")
        settled.assertForOverFulfill = false
        let (resume, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let service = PrivatePaykitService(messageRetryOperations: .init(
            now: { now },
            sleep: { delay in
                sleeps += 1
                if sleeps == 1 { await armCooldown?() }
                now = now.addingTimeInterval(TimeInterval(delay) / 1_000_000_000)
                if handshakes >= 2 || sleeps == 12 {
                    settled.fulfill()
                    for await _ in resume {}
                }
            },
            currentPublicKey: { _ in "identity" },
            drain: { _ in
                .init(
                    ensureLink: { _ in
                        handshakes += 1
                        throw PaykitError.Transport(code: "offline", context: "Unavailable homeserver")
                    },
                    pendingOutbound: { [] }, linkedPeers: { [] },
                    processPending: { _ in XCTFail("No outbound messages") },
                    receive: { _ in XCTFail("No linked peer") }
                )
            },
            didLink: { _, _ in XCTFail("Unreachable peer cannot link") }
        ))
        _ = await service.rememberSavedContacts([key], replacing: true)
        armCooldown = {
            _ = await service.syncLocalEndpointPublication(
                for: [key], reason: "test", requireImmediatePublication: false,
                operations: .init(
                    currentPublicKey: { "pubkylocal" },
                    ensureLink: { _ in
                        publicationHandshakes += 1
                        throw PaykitError.Transport(code: "offline", context: "Unavailable homeserver")
                    },
                    buildEndpoints: { _ in XCTFail("Failed links must not reserve addresses"); return [] },
                    syncPaymentLists: { _ in .init(queued: [], cleared: [], failedToQueue: [], failedToDeliver: []) },
                    linkedPeers: { [] }
                )
            )
        }
        await service.scheduleExplicitContactLink(publicKey: key, identity: "identity")
        let task = await service.pendingMessageDrainRetryTask
        let completion = Task { await task?.value; settled.fulfill() }
        await fulfillment(of: [settled], timeout: 2)
        let retry = await service.pendingMessageDrainRetries[key]
        XCTAssertEqual(publicationHandshakes, 1)
        XCTAssertNotNil(retry)
        XCTAssertEqual(handshakes, 2)
        await service.invalidateContactPreparation()
        continuation.finish()
        await completion.value
    }

    func testExplicitRetryCoalescesIdentityChecksWithoutReusingAcrossReads() async {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        let key = "pubky" + String(repeating: "y", count: 52)
        for changedDuring in ["none", "peers", "outbound"] {
            var identity = "identity"
            var identityReads = 0
            var receives = 0
            var completions = 0
            let service = PrivatePaykitService(messageRetryOperations: .init(
                currentPublicKey: { _ in identityReads += 1; return identity },
                drain: { _ in
                    .init(
                        ensureLink: { _ in XCTFail("Already linked") },
                        pendingOutbound: {
                            if changedDuring == "outbound" { identity = "other" }
                            return []
                        },
                        linkedPeers: {
                            if changedDuring == "peers" { identity = "other" }
                            return [self.drainPeer(key)]
                        },
                        processPending: { _ in XCTFail("No outbound messages") },
                        receive: { _ in receives += 1 }
                    )
                },
                didLink: { _, _ in completions += 1 }
            ))
            _ = await service.rememberSavedContacts([key], replacing: true)
            await service.scheduleExplicitContactLink(publicKey: key, identity: identity)
            let task = await service.pendingMessageDrainRetryTask
            await task?.value
            XCTAssertEqual(receives, changedDuring == "none" ? 1 : 0)
            XCTAssertEqual(completions, changedDuring == "none" ? 1 : 0)
            if changedDuring == "none" { XCTAssertLessThanOrEqual(identityReads, 7) }
            await service.invalidateContactPreparation()
        }
    }

    func testExplicitRetryBacksOffIdentityInspectionFailuresAndRecoversAfterAdmittedWrite() async {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        let key = "pubky" + String(repeating: "y", count: 52)
        let startedAt = Date(timeIntervalSince1970: 100)
        var now = startedAt
        var inspectionFails = true
        var sent = false
        var receives = 0
        var delays: [UInt64] = []
        let firstBackoff = expectation(description: "Initial inspection failure backs off")
        let secondBackoff = expectation(description: "Post-write inspection failure backs off")
        let completed = expectation(description: "Recovered identity completes intake")
        let (firstResume, firstContinuation) = AsyncStream<Void>.makeStream()
        let (secondResume, secondContinuation) = AsyncStream<Void>.makeStream()
        defer { firstContinuation.finish(); secondContinuation.finish() }
        let service = PrivatePaykitService(messageRetryOperations: .init(
            now: { now },
            sleep: { delay in
                delays.append(delay)
                if delays.count == 1 {
                    firstBackoff.fulfill()
                    for await _ in firstResume {}
                } else {
                    secondBackoff.fulfill()
                    for await _ in secondResume {}
                }
                now = now.addingTimeInterval(TimeInterval(delay) / 1_000_000_000)
            },
            currentPublicKey: { _ in
                if inspectionFails { throw PaykitError.Transport(code: "offline", context: "Registry unavailable") }
                return "identity"
            },
            drain: { _ in
                XCTAssertFalse(inspectionFails)
                return .init(
                    ensureLink: { _ in XCTFail("Peer is already linked") },
                    pendingOutbound: { sent ? [] : [key] },
                    linkedPeers: { [self.drainPeer(key)] },
                    processPending: { _ in
                        XCTAssertFalse(sent)
                        sent = true
                        inspectionFails = true
                    },
                    receive: { _ in receives += 1 }
                )
            },
            didLink: { _, _ in completed.fulfill() }
        ))
        _ = await service.rememberSavedContacts([key], replacing: true)
        await service.scheduleExplicitContactLink(publicKey: key, identity: "identity")
        await fulfillment(of: [firstBackoff], timeout: 2)
        let initial = await service.pendingMessageDrainRetries[key]
        XCTAssertEqual(initial?.nextAttemptAt, startedAt.addingTimeInterval(1))
        XCTAssertFalse(sent)
        inspectionFails = false
        firstContinuation.finish()
        await fulfillment(of: [secondBackoff], timeout: 2)
        let retained = await service.pendingMessageDrainRetries[key]
        XCTAssertEqual(retained?.id, initial?.id)
        XCTAssertEqual(retained?.foregroundUntil, startedAt.addingTimeInterval(20))
        XCTAssertEqual(retained?.nextAttemptAt, startedAt.addingTimeInterval(4))
        XCTAssertEqual(delays, [1_000_000_000, 3_000_000_000])
        XCTAssertTrue(sent)
        XCTAssertEqual(receives, 0)
        inspectionFails = false
        let task = await service.pendingMessageDrainRetryTask
        secondContinuation.finish()
        await fulfillment(of: [completed], timeout: 2)
        await task?.value
        XCTAssertEqual(receives, 1)
        let remaining = await service.pendingMessageDrainRetries[key]
        XCTAssertNil(remaining)
        await service.invalidateContactPreparation()
    }

    @MainActor
    func testExplicitLinkStartRetainsIntentWhenIdentityInspectionFails() async throws {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        UserDefaults.standard.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
        let savedSecret = try Keychain.load(key: .pubkySecretKey)
        addTeardownBlock {
            if let savedSecret {
                try Keychain.upsert(key: .pubkySecretKey, data: savedSecret)
            } else {
                try Keychain.delete(key: .pubkySecretKey)
            }
        }
        let secret = String(repeating: "01", count: 32)
        try Keychain.upsert(key: .pubkySecretKey, data: Data(secret.utf8))
        let identity = try XCTUnwrap(PubkyPublicKeyFormat.normalized(PubkyService.pubkyPublicKeyFromSecret(secretKeyHex: secret)))
        let key = "pubky" + String(repeating: "y", count: 52)
        let inspected = expectation(description: "Preparation and retry inspect identity")
        inspected.expectedFulfillmentCount = 2
        let backedOff = expectation(description: "Explicit intent remains scheduled")
        let now = Date(timeIntervalSince1970: 100)
        let service = PrivatePaykitService(messageRetryOperations: .init(
            now: { now },
            sleep: { delay in
                XCTAssertEqual(delay, 1_000_000_000)
                backedOff.fulfill()
                try await Task.sleep(for: .seconds(3600))
            },
            currentPublicKey: { _ in
                inspected.fulfill()
                throw PaykitError.Transport(code: "offline", context: "Registry unavailable")
            },
            drain: { _ in XCTFail("Unverified identity must not drain"); return .live() }
        ))
        await service.startExplicitContactLink(publicKey: key, expectedIdentity: identity, wallet: WalletViewModel())
        await fulfillment(of: [inspected, backedOff], timeout: 2)
        let retry = await service.pendingMessageDrainRetries[key]
        XCTAssertEqual(retry?.expectedIdentity, identity)
        XCTAssertEqual(retry?.foregroundUntil, now.addingTimeInterval(20))
        XCTAssertEqual(retry?.nextAttemptAt, now.addingTimeInterval(1))
        let preparation = await service.preparationTask
        XCTAssertNil(preparation)
        let task = await service.pendingMessageDrainRetryTask
        await service.invalidateContactPreparation()
        await task?.value
    }

    func testExplicitRetryRetainsFailedIntakeUntilRecoveryOrForegroundExpiry() async {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        for expires in [false, true] {
            let key = "pubky" + String(repeating: "y", count: 52)
            let startedAt = Date(timeIntervalSince1970: 100)
            var now = startedAt
            var receiveFails = true
            var priorities: [PaykitSdkOperationLock.Priority] = []
            let backedOff = expectation(description: "Failed intake remains scheduled")
            let completed = expectation(description: "Only successful foreground intake signals readiness")
            completed.isInverted = expires
            let (resume, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            let service = PrivatePaykitService(messageRetryOperations: .init(
                now: { now },
                sleep: { delay in
                    XCTAssertEqual(delay, 1_000_000_000)
                    backedOff.fulfill()
                    for await _ in resume {}
                },
                currentPublicKey: { _ in "identity" },
                drain: { priority in
                    .init(
                        ensureLink: { _ in XCTFail("Peer is already linked") }, pendingOutbound: { [] },
                        linkedPeers: { [self.drainPeer(key)] },
                        processPending: { _ in XCTFail("No outbound messages") },
                        receive: { _ in
                            priorities.append(priority)
                            if receiveFails { throw PaykitError.Transport(code: "offline", context: "Intake unavailable") }
                        }
                    )
                },
                didLink: { _, _ in completed.fulfill() }
            ))
            _ = await service.rememberSavedContacts([key], replacing: true)
            await service.scheduleExplicitContactLink(publicKey: key, identity: "identity")
            await fulfillment(of: [backedOff], timeout: 2)
            let retry = await service.pendingMessageDrainRetries[key]
            XCTAssertEqual(retry?.foregroundUntil, startedAt.addingTimeInterval(20))
            XCTAssertEqual(retry?.nextAttemptAt, startedAt.addingTimeInterval(1))
            now = startedAt.addingTimeInterval(expires ? 20 : 1)
            receiveFails = expires
            let task = await service.pendingMessageDrainRetryTask
            continuation.finish()
            await task?.value
            await fulfillment(of: [completed], timeout: expires ? 0.1 : 2)
            XCTAssertEqual(priorities, [.interactive, expires ? .background : .interactive])
            let remaining = await service.pendingMessageDrainRetries[key]
            XCTAssertNil(remaining)
            await service.invalidateContactPreparation()
        }
    }

    func testRecoveredMissingPeerRetriesFailedIntake() async {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        let key = "pubky" + String(repeating: "y", count: 52)
        var now = Date(timeIntervalSince1970: 100)
        var linked = false
        var pending = true
        var receives = 0
        var completions = 0
        let service = PrivatePaykitService(messageRetryOperations: .init(
            now: { now },
            sleep: { delay in
                now = now.addingTimeInterval(TimeInterval(delay) / 1_000_000_000)
                linked = true
            },
            currentPublicKey: { _ in "identity" },
            drain: { _ in
                .init(
                    ensureLink: { _ in throw PaykitError.NotFound(code: "missing", context: "Peer unavailable") },
                    pendingOutbound: { pending ? [key] : [] },
                    linkedPeers: { [self.drainPeer(key, state: linked ? .linked : .notLinked)] },
                    processPending: { _ in
                        guard linked else { throw PaykitError.Transport(code: "offline", context: "Delivery unavailable") }
                        pending = false
                    },
                    receive: { _ in
                        receives += 1
                        if receives == 1 { throw PaykitError.Transport(code: "offline", context: "Intake unavailable") }
                    }
                )
            },
            didLink: { _, _ in completions += 1 }
        ))
        _ = await service.rememberSavedContacts([key], replacing: true)
        await service.scheduleExplicitContactLink(publicKey: key, identity: "identity")
        let task = await service.pendingMessageDrainRetryTask
        await task?.value
        XCTAssertFalse(pending)
        XCTAssertEqual(receives, 2)
        XCTAssertEqual(completions, 1)
        let remaining = await service.pendingMessageDrainRetries[key]
        XCTAssertNil(remaining)
        await service.invalidateContactPreparation()
    }

    func testExplicitLinkWindowUsesExistingBackoffAndDoesNotExtendOnDuplicate() async throws {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        let now = Date(timeIntervalSince1970: 100)
        let key = "pubky" + String(repeating: "y", count: 52)
        let service = PrivatePaykitService(messageRetryOperations: .init(now: { now }))
        await service.setBackgroundWorkPaused(true)
        _ = await service.rememberSavedContacts([key], replacing: true)
        await service.scheduleExplicitContactLink(publicKey: key, identity: "identity")
        let initial = await service.pendingMessageDrainRetries[key]
        await service.scheduleExplicitContactLink(publicKey: key, identity: "identity")
        await service.schedulePrivatePaymentRecovery(for: key)
        let repeated = await service.pendingMessageDrainRetries[key]
        XCTAssertEqual(initial?.id, repeated?.id)
        XCTAssertEqual(repeated?.foregroundUntil, now.addingTimeInterval(20))
        XCTAssertEqual(repeated?.nextAttemptAt, now)
        var retry = try XCTUnwrap(initial)
        for (completedAt, nextAt) in [(0.0, 1.0), (1, 4), (4, 12), (12, 32), (32, 77), (77, 167)] {
            retry.completeAttempt(at: now.addingTimeInterval(completedAt))
            XCTAssertEqual(retry.nextAttemptAt, now.addingTimeInterval(nextAt))
        }
        XCTAssertEqual(retry.priority(at: now.addingTimeInterval(19)), .interactive)
        XCTAssertEqual(retry.priority(at: now.addingTimeInterval(20)), .background)
        await service.invalidateContactPreparation()
    }

    func testExplicitLinkJoinsAdmittedPreparationAndCoalescesCompletion() async {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        let key = "pubky" + String(repeating: "y", count: 52)
        let started = expectation(description: "Preparation admitted")
        let completed = expectation(description: "One targeted completion")
        let (resume, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        var advances = 0
        var linked = false
        var receives = 0
        let operations = PrivatePaykitService.PrivateMessageDrainOperations(
            ensureLink: { _ in
                advances += 1
                started.fulfill()
                for await _ in resume {}
                XCTAssertFalse(Task.isCancelled)
                linked = true
            },
            pendingOutbound: { [] },
            linkedPeers: { [self.drainPeer(key, state: linked ? .linked : .linking)] },
            processPending: { _ in },
            receive: { _ in receives += 1 }
        )
        let service = PrivatePaykitService(messageRetryOperations: .init(
            currentPublicKey: { _ in "identity" }, drain: { _ in operations }, didLink: { _, _ in completed.fulfill() }
        ))
        _ = await service.rememberSavedContacts([key], replacing: true)
        let preparation = Task {
            await service.drainPendingPrivateMessages(reason: "preparation", advancing: [key], operations: operations)
        }
        await fulfillment(of: [started], timeout: 2)
        await service.scheduleExplicitContactLink(publicKey: key, identity: "identity")
        await service.scheduleExplicitContactLink(publicKey: key, identity: "identity")
        let caller = Task { await service.schedulePrivatePaymentRecovery(for: key) }
        caller.cancel()
        await caller.value
        continuation.finish()
        await preparation.value
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(advances, 1)
        XCTAssertGreaterThan(receives, 0)
        await service.invalidateContactPreparation()
    }

    func testExplicitRetryPausesAfterAdmittedWriteAndRejectsStaleIdentity() async {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        for change in ["resume", "expired", "identity", "generation", "deletion", "contact"] {
            let key = "pubky" + String(repeating: "y", count: 52)
            let admitted = expectation(description: "Write admitted")
            let finished = expectation(description: "Admitted write finishes")
            let ready = expectation(description: "Current identity is refreshed")
            ready.isInverted = change != "resume"
            let (resume, continuation) = AsyncStream<Void>.makeStream()
            var identity = "identity"
            var sent = false
            var now = Date(timeIntervalSince1970: 100)
            var laterPriorities: [PaykitSdkOperationLock.Priority] = []
            let operations = PrivatePaykitService.PrivateMessageDrainOperations(
                ensureLink: { _ in }, pendingOutbound: { sent ? [] : [key] },
                linkedPeers: { [self.drainPeer(key)] },
                processPending: { _ in
                    admitted.fulfill()
                    for await _ in resume {}
                    XCTAssertFalse(Task.isCancelled)
                    sent = true
                    finished.fulfill()
                },
                receive: { _ in XCTAssertTrue(change == "resume" || change == "expired") }
            )
            let service = PrivatePaykitService(messageRetryOperations: .init(
                now: { now }, currentPublicKey: { _ in identity },
                drain: { priority in
                    if sent { laterPriorities.append(priority) }
                    return operations
                }, didLink: { _, _ in ready.fulfill() }
            ))
            _ = await service.rememberSavedContacts([key], replacing: true)
            await service.scheduleExplicitContactLink(publicKey: key, identity: identity)
            await fulfillment(of: [admitted], timeout: 2)
            await service.setBackgroundWorkPaused(true)
            continuation.finish()
            await fulfillment(of: [finished], timeout: 2)
            switch change {
            case "expired": now = now.addingTimeInterval(20)
            case "identity": identity = "other"
            case "generation": await service.invalidateContactPreparation()
            case "deletion": await service.beginProfileDeletion()
            case "contact": _ = await service.rememberSavedContacts([], replacing: true)
            default: break
            }
            await service.setBackgroundWorkPaused(false)
            await fulfillment(of: [ready], timeout: change == "resume" ? 2 : 0.1)
            if change == "expired" {
                XCTAssertFalse(laterPriorities.isEmpty)
                XCTAssertTrue(laterPriorities.allSatisfy { $0 == .background })
            }
            let task = await service.pendingMessageDrainRetryTask
            await service.invalidateContactPreparation()
            await task?.value
        }
    }

    func testDueBackgroundPeerRunsBetweenForegroundBursts() async {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        let keys = ["y", "o", "e", "u", "i"].map { "pubky" + String(repeating: $0, count: 52) }
        let now = Date(timeIntervalSince1970: 100)
        var linkedKeys = Set<String>()
        var advances: [PaykitSdkOperationLock.Priority] = []
        let service = PrivatePaykitService(messageRetryOperations: .init(
            now: { now }, currentPublicKey: { _ in "identity" },
            drain: { priority in
                .init(
                    ensureLink: { key in linkedKeys.insert(key); advances.append(priority) },
                    pendingOutbound: { [] },
                    linkedPeers: { keys.map { self.drainPeer($0, state: linkedKeys.contains($0) ? .linked : .linking) } },
                    processPending: { _ in }, receive: { _ in }
                )
            }, didLink: { _, _ in }
        ))
        await service.setBackgroundWorkPaused(true)
        _ = await service.rememberSavedContacts(keys, replacing: true)
        await service.setTestRetry(.init(nextAttemptAt: now), for: keys[0])
        await service.schedulePrivatePaymentRecovery(for: keys[0])
        for key in keys.dropFirst() {
            await service.scheduleExplicitContactLink(publicKey: key, identity: "identity")
        }
        let task = await service.pendingMessageDrainRetryTask
        await service.setBackgroundWorkPaused(false)
        await task?.value
        XCTAssertEqual(advances, [.interactive, .interactive, .interactive, .background, .interactive])
    }

    func testDuePeersShareSchedulingReadsAndInspectStateAfterEachMutation() async {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        let keys = ["e", "o", "y"].map { "pubky" + String(repeating: $0, count: 52) }
        for explicit in [false, true] {
            let now = Date(timeIntervalSince1970: 100)
            var linked = Set<String>()
            var pending = Set<String>()
            var sent: [String] = []
            var received: [String] = []
            var peerReads = 0
            var outboundReads = 0
            let service = PrivatePaykitService(messageRetryOperations: .init(
                now: { now }, currentPublicKey: { _ in "identity" },
                drain: { priority in
                    XCTAssertEqual(priority, explicit ? .interactive : .background)
                    return .init(
                        ensureLink: { key in
                            XCTAssertTrue(linked.insert(key).inserted)
                            pending.insert(key)
                        },
                        pendingOutbound: { outboundReads += 1; return Array(pending) },
                        linkedPeers: {
                            peerReads += 1
                            return keys.map { self.drainPeer($0, state: linked.contains($0) ? .linked : .linking) }
                        },
                        processPending: { key in
                            XCTAssertNotNil(pending.remove(key))
                            sent.append(key)
                        },
                        receive: { key in
                            XCTAssertTrue(linked.contains(key))
                            XCTAssertFalse(pending.contains(key))
                            received.append(key)
                        }
                    )
                }, didLink: { _, _ in }
            ))
            await service.setBackgroundWorkPaused(true)
            _ = await service.rememberSavedContacts(keys, replacing: true)
            for key in keys {
                if explicit {
                    await service.scheduleExplicitContactLink(publicKey: key, identity: "identity")
                } else {
                    await service.setTestRetry(.init(nextAttemptAt: now), for: key)
                    await service.schedulePrivatePaymentRecovery(for: key)
                }
            }
            let task = await service.pendingMessageDrainRetryTask
            await service.setBackgroundWorkPaused(false)
            await task?.value
            XCTAssertEqual(sent, keys)
            XCTAssertEqual(received, keys)
            XCTAssertEqual(peerReads, 7)
            XCTAssertEqual(outboundReads, explicit ? 6 : 7)
            let retries = await service.pendingMessageDrainRetryKeys
            XCTAssertTrue(retries.isEmpty)
        }
    }

    func testDuePeerSnapshotIsDiscardedAfterPreparationPauseOrIdentityInvalidation() async {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        let keys = ["o", "y"].map { "pubky" + String(repeating: $0, count: 52) }
        for change in ["preparation", "resume", "expired", "identity", "generation", "cancel"] {
            var now = Date(timeIntervalSince1970: 100)
            var identity = "identity"
            var secondLinked = change != "preparation"
            var advanced: [String] = []
            var received: [String] = []
            var priorities: [PaykitSdkOperationLock.Priority] = []
            let firstCompleted = expectation(description: "First due contact completed")
            let (resume, continuation) = AsyncStream<Void>.makeStream()
            let service = PrivatePaykitService(messageRetryOperations: .init(
                now: { now }, currentPublicKey: { _ in identity },
                drain: { priority in
                    .init(
                        ensureLink: { key in
                            XCTAssertFalse(secondLinked)
                            advanced.append(key)
                            priorities.append(priority)
                            secondLinked = true
                        },
                        pendingOutbound: { [] },
                        linkedPeers: {
                            [self.drainPeer(keys[0]), self.drainPeer(keys[1], state: secondLinked ? .linked : .linking)]
                        },
                        processPending: { _ in XCTFail("No outbound messages") },
                        receive: { received.append($0) }
                    )
                }, didLink: { _, key in
                    if key == keys[0] {
                        firstCompleted.fulfill()
                        for await _ in resume {}
                    }
                }
            ))
            await service.setBackgroundWorkPaused(true)
            _ = await service.rememberSavedContacts(keys, replacing: true)
            for key in keys {
                await service.scheduleExplicitContactLink(publicKey: key, identity: identity)
            }
            let task = await service.pendingMessageDrainRetryTask
            await service.setBackgroundWorkPaused(false)
            await fulfillment(of: [firstCompleted], timeout: 2)
            if change != "preparation" {
                await service.setBackgroundWorkPaused(true)
                secondLinked = false
            }
            switch change {
            case "preparation":
                await service.drainPendingPrivateMessages(reason: "preparation", advancing: [keys[1]], operations: .init(
                    ensureLink: { _ in secondLinked = true }, pendingOutbound: { [] },
                    linkedPeers: { [self.drainPeer(keys[1], state: secondLinked ? .linked : .linking)] },
                    processPending: { _ in XCTFail("No outbound messages") }, receive: { _ in }
                ))
            case "expired": now = now.addingTimeInterval(20)
            case "identity": identity = "other"
            case "generation": await service.invalidateContactPreparation()
            case "cancel": task?.cancel()
            default: break
            }
            XCTAssertEqual(received, [keys[0]])
            continuation.finish()
            await service.setBackgroundWorkPaused(false)
            await task?.value
            let resumes = change == "resume" || change == "expired"
            XCTAssertEqual(advanced, resumes ? [keys[1]] : [])
            XCTAssertEqual(received, resumes || change == "preparation" ? keys : [keys[0]])
            XCTAssertEqual(priorities, resumes ? [change == "expired" ? .background : .interactive] : [])
            await service.invalidateContactPreparation()
        }
    }

    func testRetryRereadsSchedulingStateAfterTimerWait() async {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        let key = "pubky" + String(repeating: "y", count: 52)
        var now = Date(timeIntervalSince1970: 100)
        var linked = false
        var advances = 0
        var receives = 0
        let service = PrivatePaykitService(messageRetryOperations: .init(
            now: { now },
            sleep: { delay in
                XCTAssertEqual(delay, 1_000_000_000)
                now = now.addingTimeInterval(1)
                linked = true
            },
            currentPublicKey: { _ in "identity" },
            drain: { _ in
                .init(
                    ensureLink: { _ in
                        XCTAssertFalse(linked)
                        advances += 1
                    },
                    pendingOutbound: { [] },
                    linkedPeers: { [self.drainPeer(key, state: linked ? .linked : .linking)] },
                    processPending: { _ in XCTFail("No outbound messages") },
                    receive: { _ in receives += 1 }
                )
            }, didLink: { _, _ in }
        ))
        await service.setBackgroundWorkPaused(true)
        _ = await service.rememberSavedContacts([key], replacing: true)
        await service.scheduleExplicitContactLink(publicKey: key, identity: "identity")
        let task = await service.pendingMessageDrainRetryTask
        await service.setBackgroundWorkPaused(false)
        await task?.value
        XCTAssertEqual(advances, 1)
        XCTAssertEqual(receives, 1)
        let retries = await service.pendingMessageDrainRetryKeys
        XCTAssertTrue(retries.isEmpty)
    }

    func testPendingEndpointReconciliationRestoresSavedContactsWhenPublishingRemainsEnabled() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(true, forKey: PrivatePaykitService.cleanupPendingKey)
            defaults.set(true, forKey: PrivatePaykitService.publishingEnabledKey)

            XCTAssertEqual(
                PrivatePaykitService.fullCleanupReconciliationMode(defaults: defaults),
                .restoreSavedContacts
            )
        }
    }

    func testPendingEndpointReconciliationRemovesPublishedStateWhenPublishingIsDisabled() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(true, forKey: PrivatePaykitService.cleanupPendingKey)
            defaults.set(false, forKey: PrivatePaykitService.publishingEnabledKey)

            XCTAssertEqual(
                PrivatePaykitService.fullCleanupReconciliationMode(defaults: defaults),
                .removePublishedState
            )
        }
    }

    @MainActor
    func testPendingEndpointReconciliationKeepsKnownContactsWhenLoadedListIsEmpty() async {
        let defaults = UserDefaults.standard
        let previousCleanupPending = defaults.object(forKey: PrivatePaykitService.cleanupPendingKey)
        let previousPublishingEnabled = defaults.object(forKey: PrivatePaykitService.publishingEnabledKey)
        defer {
            defaults.set(previousCleanupPending, forKey: PrivatePaykitService.cleanupPendingKey)
            defaults.set(previousPublishingEnabled, forKey: PrivatePaykitService.publishingEnabledKey)
        }

        defaults.set(true, forKey: PrivatePaykitService.cleanupPendingKey)
        defaults.set(true, forKey: PrivatePaykitService.publishingEnabledKey)
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let service = PrivatePaykitService()
        _ = await service.rememberSavedContacts([publicKey], replacing: true)

        await service.retryPendingEndpointReconciliation(wallet: WalletViewModel(), savedPublicKeys: [])

        let knownSavedContactKeys = await service.knownSavedContactKeys
        XCTAssertEqual(knownSavedContactKeys, [publicKey])
        XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
    }

    func testPreparingSavedContactsDefersWhenPublicationIsUnavailable() async {
        let service = PrivatePaykitService()
        let contacts = ["pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"]
        var preparedContacts = [String]()
        let error = await service.prepareSavedContacts(
            contacts,
            publicationUnavailableReason: "the Lightning node is not running",
            prepareLinks: { preparedContacts = $0 },
            publishEndpoints: { _ in
                XCTFail("Unavailable endpoints must not be published")
                return PrivatePaykitError.privateUnavailable
            }
        )

        XCTAssertNil(error)
        XCTAssertEqual(preparedContacts, contacts)
    }

    @MainActor
    func testPreparingSavedContactsPublishesReservationsInBackground() async throws {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let endpoint = PublicPaykitService.Endpoint(
            methodId: .regtestOnchainP2wpkh, value: "bcrt1qendpoint", min: nil, max: nil,
            rawPayload: #"{"value":"bcrt1qendpoint"}"#
        )
        let publishing = expectation(description: "Private reservation publication started")
        let published = expectation(description: "Private reservations published")
        let (resume, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        var syncedUpdates = [PrivatePaymentListReservationUpdateInput]()
        let service = PrivatePaykitService(publicationOperations: .init(
            currentPublicKey: { "pubkylocal" },
            ensureLink: { _ in .linked },
            buildEndpoints: { key in
                XCTAssertEqual(key, publicKey)
                return [endpoint]
            },
            syncPaymentLists: { updates in
                publishing.fulfill()
                for await _ in resume {
                    break
                }
                syncedUpdates = updates
                published.fulfill()
                return .init(queued: [], cleared: [], failedToQueue: [], failedToDeliver: [])
            }
        ))

        let error = await service.prepareSavedContacts([publicKey], wallet: WalletViewModel())
        await fulfillment(of: [publishing], timeout: 2)
        let returnedBeforePublication = expectation(description: "Preparation wait does not finish before publication")
        returnedBeforePublication.isInverted = true
        let waiter = Task {
            try await service.awaitContactPreparation()
            if syncedUpdates.isEmpty { returnedBeforePublication.fulfill() }
        }
        await fulfillment(of: [returnedBeforePublication], timeout: 0.1)
        continuation.finish()
        try await waiter.value
        await fulfillment(of: [published], timeout: 2)

        XCTAssertNil(error)
        XCTAssertEqual(syncedUpdates.count, 1)
        let update = try XCTUnwrap(syncedUpdates.first)
        XCTAssertEqual(update.counterparty, publicKey)
        XCTAssertEqual(update.reservations.count, 1)
        let reservation = try XCTUnwrap(update.reservations.first)
        XCTAssertEqual(reservation.identifier, endpoint.methodId.rawValue)
        XCTAssertEqual(reservation.payload, endpoint.rawPayload)
        XCTAssertEqual(reservation.attribution["counterparty"], publicKey)
    }

    @MainActor
    func testBackgroundPreparationStopsPublicationWhenSessionEnds() async throws {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        var isSessionCurrent = true
        let preparing = expectation(description: "Background preparation reached the link")
        let (resume, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let service = PrivatePaykitService(publicationOperations: .init(
            currentPublicKey: { "pubkylocal" },
            ensureLink: { _ in
                preparing.fulfill()
                for await _ in resume {
                    break
                }
                return .linked
            },
            buildEndpoints: { _ in XCTFail("Ended sessions must not build endpoints"); return [] },
            syncPaymentLists: { _ in
                XCTFail("Ended sessions must not publish")
                return .init(queued: [], cleared: [], failedToQueue: [], failedToDeliver: [])
            }
        ))

        _ = await service.prepareSavedContacts(
            [publicKey], wallet: WalletViewModel(), isSessionCurrent: { isSessionCurrent }
        )
        await fulfillment(of: [preparing], timeout: 2)
        isSessionCurrent = false
        continuation.finish()
        try await service.awaitContactPreparation()
    }

    @MainActor
    func testBackgroundPreparationUsesTheLatestSessionsQueuedWork() async throws {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let endpoint = PublicPaykitService.Endpoint(
            methodId: .regtestOnchainP2wpkh, value: "bcrt1qendpoint", min: nil, max: nil,
            rawPayload: #"{"value":"bcrt1qendpoint"}"#
        )
        var session = 1
        var started = false
        var published = [String]()
        let preparing = expectation(description: "Original preparation started")
        let (resume, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let service = PrivatePaykitService(publicationOperations: .init(
            currentPublicKey: { "pubkylocal" },
            ensureLink: { _ in
                if !started {
                    started = true
                    preparing.fulfill()
                    for await _ in resume {
                        break
                    }
                }
                return .linked
            },
            buildEndpoints: { _ in [endpoint] },
            syncPaymentLists: { updates in
                published += updates.map(\.counterparty)
                return .init(queued: [], cleared: [], failedToQueue: [], failedToDeliver: [])
            }
        ))

        _ = await service.prepareSavedContacts([publicKey], wallet: WalletViewModel(), isSessionCurrent: { session == 1 })
        await fulfillment(of: [preparing], timeout: 2)
        session = 2
        _ = await service.prepareSavedContacts([publicKey], wallet: WalletViewModel(), isSessionCurrent: { session == 2 })
        continuation.finish()
        try await service.awaitContactPreparation()

        XCTAssertEqual(published, [publicKey])
    }

    func testCancellingPreparationWaitLeavesSharedPreparationRunning() async throws {
        let service = PrivatePaykitService()
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        _ = await service.rememberSavedContacts([publicKey], replacing: true)
        let started = expectation(description: "Preparation started")
        let finished = expectation(description: "Shared preparation finished")
        let (resume, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        await service.scheduleContactPreparation([publicKey]) { _, _ in
            started.fulfill()
            for await _ in resume {
                break
            }
            XCTAssertFalse(Task.isCancelled)
            finished.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        let cancelled = expectation(description: "Preparation wait cancelled")
        let returnedBeforeCancellation = expectation(description: "Preparation wait remains suspended")
        returnedBeforeCancellation.isInverted = true
        let waiter = Task {
            do {
                try await service.awaitContactPreparation()
                returnedBeforeCancellation.fulfill()
            } catch is CancellationError {
                cancelled.fulfill()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        await fulfillment(of: [returnedBeforeCancellation], timeout: 0.1)
        waiter.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        continuation.finish()
        try await service.awaitContactPreparation()
        await fulfillment(of: [finished], timeout: 2)
        await waiter.value
    }

    func testPrivateMessageDrainUsesLinkAndOutboundStateAfterAdvancement() async {
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        for isLinked in [false, true] {
            for hasOutbound in [false, true] {
                let service = PrivatePaykitService()
                var advanced = false
                var processed = 0
                var received = 0
                await service.drainPendingPrivateMessages(reason: "test", advancing: [publicKey], operations: .init(
                    ensureLink: { key in
                        XCTAssertEqual(key, publicKey)
                        advanced = true
                    },
                    pendingOutbound: {
                        XCTAssertTrue(advanced)
                        return hasOutbound ? [publicKey] : []
                    },
                    linkedPeers: {
                        return [LinkedPeerRecord(
                            counterparty: publicKey, state: advanced && isLinked ? .linked : .linking,
                            lastSyncAt: nil, lastPrivateReceiveAt: nil, failureCount: 0,
                            localRecoveryAttemptId: nil, localRecoveryMarkerCreatedAt: nil, localRecoveryMarkerLastError: nil,
                            remoteRecoveryAttemptId: nil, remoteRecoveryMarkerObservedAt: nil
                        )]
                    },
                    processPending: { key in
                        XCTAssertEqual(key, publicKey)
                        processed += 1
                    },
                    receive: { key in
                        XCTAssertEqual(key, publicKey)
                        received += 1
                    }
                ))

                XCTAssertTrue(advanced)
                XCTAssertEqual(processed, hasOutbound ? 1 : 0)
                XCTAssertEqual(received, isLinked ? 1 : 0)
            }
        }
    }

    func testPrivateMessageDrainSkipsLinkedPeersWithoutSkippingSendOrReceive() async {
        let service = PrivatePaykitService()
        let keys = ["first", "second"]
        var advanced: [String] = []
        var sent: [String] = []
        var received: [String] = []
        for _ in 0 ..< 2 {
            await service.drainPendingPrivateMessages(reason: "test", advancing: keys, operations: .init(
                ensureLink: { advanced.append($0) },
                pendingOutbound: { keys },
                linkedPeers: { keys.map { self.drainPeer($0) } },
                processPending: { sent.append($0) },
                receive: { received.append($0) }
            ))
        }
        XCTAssertEqual(advanced, [])
        XCTAssertEqual(sent, keys + keys)
        XCTAssertEqual(received, keys + keys)
    }

    func testOverlappingLinkPreparationRetriesAfterFailureOrCancellation() async {
        for cancel in [false, true] {
            let service = PrivatePaykitService()
            let started = expectation(description: "Link preparation started")
            let (resume, continuation) = AsyncStream<Void>.makeStream()
            var advances = 0
            let operations = PrivatePaykitService.PrivateMessageDrainOperations(
                ensureLink: { _ in
                    advances += 1
                    if advances == 1 {
                        started.fulfill()
                        for await _ in resume {
                            break
                        }
                        try Task.checkCancellation()
                        throw PrivatePaykitError.privateUnavailable
                    }
                },
                pendingOutbound: { [] }, linkedPeers: { [] }, processPending: { _ in }, receive: { _ in }
            )
            let first = Task {
                await service.drainPendingPrivateMessages(reason: "test", advancing: ["peer"], operations: operations)
            }
            await fulfillment(of: [started], timeout: 2)
            await service.drainPendingPrivateMessages(reason: "test", advancing: ["peer"], operations: operations)
            XCTAssertEqual(advances, 1)
            if cancel { first.cancel() }
            continuation.finish()
            await first.value
            await service.drainPendingPrivateMessages(reason: "test", advancing: ["peer"], operations: operations)
            XCTAssertEqual(advances, 2)
        }
    }

    func testInvalidatedLinkPreparationCannotReleaseNewPreparation() async {
        let service = PrivatePaykitService()
        let oldStarted = expectation(description: "Old preparation started")
        let newStarted = expectation(description: "New preparation started")
        let (oldResume, oldContinuation) = AsyncStream<Void>.makeStream()
        let (newResume, newContinuation) = AsyncStream<Void>.makeStream()
        var advances = 0
        let operations = PrivatePaykitService.PrivateMessageDrainOperations(
            ensureLink: { _ in
                advances += 1
                if advances == 1 {
                    oldStarted.fulfill()
                    for await _ in oldResume {
                        break
                    }
                } else if advances == 2 {
                    newStarted.fulfill()
                    for await _ in newResume {
                        break
                    }
                }
            },
            pendingOutbound: { [] }, linkedPeers: { [] }, processPending: { _ in }, receive: { _ in }
        )
        let old = Task {
            await service.drainPendingPrivateMessages(reason: "test", advancing: ["peer"], operations: operations)
        }
        await fulfillment(of: [oldStarted], timeout: 2)
        await service.invalidateContactPreparation()
        let current = Task {
            await service.drainPendingPrivateMessages(reason: "test", advancing: ["peer"], operations: operations)
        }
        await fulfillment(of: [newStarted], timeout: 2)
        oldContinuation.finish()
        await old.value
        await service.drainPendingPrivateMessages(reason: "test", advancing: ["peer"], operations: operations)
        XCTAssertEqual(advances, 2)
        newContinuation.finish()
        await current.value
    }

    func testPrivateMessageDrainAdvancesRecoveryDetectedDuringSendOnNextPass() async {
        let service = PrivatePaykitService()
        let publicKey = "peer"
        var state = LinkedPeerState.linked
        var advances = 0
        var sends = 0
        var receives = 0
        let operations = PrivatePaykitService.PrivateMessageDrainOperations(
            ensureLink: { _ in
                XCTAssertEqual(state, .recoveryRequired)
                advances += 1
                state = .linked
            },
            pendingOutbound: { [publicKey] },
            linkedPeers: { [self.drainPeer(publicKey, state: state)] },
            processPending: { _ in
                sends += 1
                if sends == 1 {
                    state = .recoveryRequired
                    throw PrivatePaykitError.privateUnavailable
                }
            },
            receive: { _ in receives += 1 }
        )
        await service.drainPendingPrivateMessages(reason: "test", advancing: [publicKey], operations: operations)
        XCTAssertEqual(advances, 0)
        XCTAssertEqual(receives, 0)
        await service.drainPendingPrivateMessages(reason: "test", advancing: [publicKey], operations: operations)
        XCTAssertEqual(advances, 1)
        XCTAssertEqual(sends, 2)
        XCTAssertEqual(receives, 1)
    }

    func testPrivateMessageDrainDoesNotVisitUnrelatedPeers() async {
        let service = PrivatePaykitService()
        let selected = "selected"
        let unrelated = (0 ..< 60).map { "unrelated-\($0)" }
        var sent: [String] = []
        var received: [String] = []
        await service.drainPendingPrivateMessages(reason: "test", advancing: [selected, selected], operations: .init(
            ensureLink: { XCTAssertEqual($0, selected) },
            pendingOutbound: { unrelated + [selected] },
            linkedPeers: { (unrelated + [selected]).map { self.drainPeer($0) } },
            processPending: { sent.append($0) },
            receive: { received.append($0) }
        ))
        XCTAssertEqual(sent, [selected])
        XCTAssertEqual(received, [selected])
    }

    func testPrivateMessageDrainMatchesNormalizedRetryAndSdkKeys() async {
        let rawKey = String(repeating: "y", count: 52)
        let publicKey = "pubky" + rawKey
        for reportedKey in [rawKey, publicKey.uppercased()] {
            let service = PrivatePaykitService()
            var advanced: [String] = []
            var sent: [String] = []
            var received: [String] = []
            await service.drainPendingPrivateMessages(
                reason: "test", advancing: [rawKey.uppercased(), publicKey], operations: .init(
                    ensureLink: { advanced.append($0) },
                    pendingOutbound: { [reportedKey, "unrelated"] },
                    linkedPeers: { [self.drainPeer(reportedKey), self.drainPeer("unrelated")] },
                    processPending: { sent.append($0) },
                    receive: { received.append($0) }
                )
            )
            XCTAssertTrue(advanced.isEmpty)
            XCTAssertEqual(sent, [publicKey])
            XCTAssertEqual(received, [publicKey])
        }
    }

    func testPrivateMessageDrainStopsAfterInvalidationAtEachSuspension() async throws {
        for stage in ["initialPeers", "link", "outbound", "send", "peers", "receive"] {
            let service = PrivatePaykitService()
            var events: [String] = []
            let record: (String) async -> Void = { event in
                events.append(event)
                if event == stage { await service.invalidateContactPreparation() }
            }
            await service.drainPendingPrivateMessages(reason: "test", advancing: ["first", "second"], operations: .init(
                ensureLink: { _ in await record("link") },
                pendingOutbound: { await record("outbound"); return ["first", "second"] },
                linkedPeers: {
                    let isInitialRead = events.isEmpty
                    await record(isInitialRead ? "initialPeers" : "peers")
                    return isInitialRead ? [] : [self.drainPeer("first"), self.drainPeer("second")]
                },
                processPending: { _ in await record("send") },
                receive: { _ in await record("receive") }
            ))
            let order = ["initialPeers", "link", "link", "outbound", "send", "send", "peers", "receive", "receive"]
            XCTAssertEqual(events, try Array(order.prefix(through: XCTUnwrap(order.firstIndex(of: stage)))), stage)
        }
    }

    func testPrivateMessageDrainContinuesOtherSelectedPeersAfterFailure() async {
        let service = PrivatePaykitService()
        var sent: [String] = []
        var received: [String] = []
        await service.drainPendingPrivateMessages(reason: "test", advancing: ["first", "second"], operations: .init(
            ensureLink: { _ in },
            pendingOutbound: { ["first", "second"] },
            linkedPeers: { [self.drainPeer("first"), self.drainPeer("second")] },
            processPending: { key in
                sent.append(key)
                if key == "first" { throw PrivatePaykitError.privateUnavailable }
            },
            receive: { key in
                received.append(key)
                if key == "first" { throw PrivatePaykitError.privateUnavailable }
            }
        ))
        XCTAssertEqual(sent, ["first", "second"])
        XCTAssertEqual(received, ["first", "second"])
    }

    func testPrivateMessageDrainStopsAfterCallerCancellation() async {
        let service = PrivatePaykitService()
        let task = Task {
            await service.drainPendingPrivateMessages(reason: "test", advancing: ["first", "second"], operations: .init(
                ensureLink: { _ in withUnsafeCurrentTask { $0?.cancel() } },
                pendingOutbound: { XCTFail("Cancelled retry must not inspect outbound work"); return [] },
                linkedPeers: { XCTAssertFalse(Task.isCancelled); return [] },
                processPending: { _ in XCTFail("Cancelled retry must not send") },
                receive: { _ in XCTFail("Cancelled retry must not receive") }
            ))
        }
        await task.value
    }

    private func drainPeer(_ publicKey: String, state: LinkedPeerState = .linked) -> LinkedPeerRecord {
        LinkedPeerRecord(
            counterparty: publicKey, state: state,
            lastSyncAt: nil, lastPrivateReceiveAt: nil, failureCount: 0,
            localRecoveryAttemptId: nil, localRecoveryMarkerCreatedAt: nil, localRecoveryMarkerLastError: nil,
            remoteRecoveryAttemptId: nil, remoteRecoveryMarkerObservedAt: nil
        )
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "PrivatePaykitServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    func testDuplicatePaymentErrorClassificationUsesWrappedAppErrorReason() {
        XCTAssertTrue(
            PrivatePaykitService.isDuplicatePaymentError(
                AppError(message: "Lightning payment failed", debugMessage: "Duplicate payment")
            )
        )

        XCTAssertFalse(
            PrivatePaykitService.isDuplicatePaymentError(
                AppError(message: "Lightning payment failed", debugMessage: "Route not found")
            )
        )
    }

    func testResolutionFailureDiagnosticsKeepRedactedPaykitReason() {
        XCTAssertEqual(
            PaykitResolutionFailureDiagnostics.reason(
                for: PaykitError.Transport(code: "transport_error", context: "do-not-log")
            ),
            "transport/transport_error"
        )
        XCTAssertEqual(
            PaykitResolutionFailureDiagnostics.reason(
                for: PaykitError.Storage(code: "do not log", context: "do-not-log")
            ),
            "storage/unknown_code"
        )
        XCTAssertEqual(
            PaykitResolutionFailureDiagnostics.reason(for: PrivatePaykitError.routeHintsUnavailable),
            "private/route_hints_unavailable"
        )
        XCTAssertEqual(
            PaykitResolutionFailureDiagnostics.reason(for: PublicPaykitError.noSupportedEndpoint),
            "public/no_supported_endpoint"
        )
    }

    func testRecoveryRequiredDiagnosticsRecognizePaykitErrors() {
        let cases: [(PaykitError, Bool)] = [
            (.RecoveryRequired(code: "link_recovery_required", context: "do-not-log"), true),
            (.Protocol(code: "link_observation_failed", context: "do-not-log"), false),
            (.Protocol(code: "protocol_error", context: "link_observation_failed"), false),
            (.Transport(code: "offline", context: "do-not-log"), false),
            (.Transport(code: "link_observation_failed", context: "do-not-log"), false),
        ]
        for (error, requiresRecovery) in cases {
            XCTAssertEqual(PaykitResolutionFailureDiagnostics.isRecoveryRequired(error), requiresRecovery)
        }
        XCTAssertFalse(PaykitResolutionFailureDiagnostics.isRecoveryRequired(PrivatePaykitError.privateUnavailable))
    }

    func testPaymentRequestWaitsForPrivateLinkRecoveryStates() {
        XCTAssertTrue(
            PrivatePaykitService.paymentRequestNeedsPrivateLinkRecovery(
                resolutionState: .recoveryPending,
                linkState: .linked
            )
        )
        XCTAssertTrue(PrivatePaykitService.paymentRequestNeedsPrivateLinkRecovery(linkState: .linking))
        XCTAssertTrue(PrivatePaykitService.paymentRequestNeedsPrivateLinkRecovery(linkState: .recoveryRequired))
        XCTAssertFalse(PrivatePaykitService.paymentRequestNeedsPrivateLinkRecovery(linkState: .linked))
        XCTAssertFalse(PrivatePaykitService.paymentRequestNeedsPrivateLinkRecovery(linkState: .notLinked))
    }

    @MainActor
    func testReceivedPrivateInvoicePersistsWhileEndpointPreparationIsPaused() async throws {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        var published = [String]()
        let service = PrivatePaykitService(publicationOperations: .init(
            currentPublicKey: { "pubkylocal" },
            ensureLink: { _ in .linked },
            buildEndpoints: { _ in [] },
            syncPaymentLists: { updates in
                published += updates.map(\.counterparty)
                return .init(queued: [], cleared: [], failedToQueue: [], failedToDeliver: [])
            }
        ))
        _ = await service.rememberSavedContacts([publicKey], replacing: true)
        await service.setTestLocalInvoice(.init(bolt11: "lnbc1private", paymentHash: "payment-hash", expiresAt: 123), publicKey: publicKey)
        await service.setBackgroundWorkPaused(true)
        let completed = expectation(description: "Received payment completes while endpoint preparation is paused")
        let receipt = Task {
            await service.handleReceivedPayment(paymentHash: "payment-hash", wallet: WalletViewModel())
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertTrue(published.isEmpty)
        let restored = PrivatePaykitService()
        let receivedHashes = await restored.testContactState(publicKey: publicKey)?.receivedInvoicePaymentHashes
        XCTAssertEqual(receivedHashes, ["payment-hash"])
        let matchedPublicKey = await restored.contactPublicKey(forPrivateInvoicePaymentHash: "payment-hash")
        XCTAssertEqual(matchedPublicKey, publicKey)

        await service.setBackgroundWorkPaused(false)
        await receipt.value
        try await service.awaitContactPreparation()
        XCTAssertEqual(published, [publicKey])
    }

    @MainActor
    func testEndpointRefreshRequeuesAnActivePreparation() async throws {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        var endpointPayload = #"{"value":"bcrt1qold"}"#
        var published = [[String]]()
        let publishing = expectation(description: "Older endpoints are being published")
        let (resume, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let service = PrivatePaykitService(publicationOperations: .init(
            currentPublicKey: { "pubkylocal" },
            ensureLink: { _ in .linked },
            buildEndpoints: { _ in
                [.init(methodId: .regtestOnchainP2wpkh, value: "bcrt1qendpoint", min: nil, max: nil, rawPayload: endpointPayload)]
            },
            syncPaymentLists: { updates in
                published.append(updates.flatMap(\.reservations).map(\.payload))
                if published.count == 1 {
                    publishing.fulfill()
                    for await _ in resume {}
                }
                return .init(queued: [], cleared: [], failedToQueue: [], failedToDeliver: [])
            }
        ))
        let wallet = WalletViewModel()
        _ = await service.prepareSavedContacts([publicKey], wallet: wallet)
        await fulfillment(of: [publishing], timeout: 2)
        endpointPayload = #"{"value":"bcrt1qnew"}"#
        let refreshed = expectation(description: "Endpoint refresh is queued without waiting for the active publication")
        let refresh = Task {
            await service.refreshSavedContactEndpoints(for: [publicKey], wallet: wallet)
            refreshed.fulfill()
        }
        await fulfillment(of: [refreshed], timeout: 2)
        continuation.finish()
        await refresh.value
        try await service.awaitContactPreparation()

        XCTAssertEqual(published, [[#"{"value":"bcrt1qold"}"#], [#"{"value":"bcrt1qnew"}"#]])
    }

    func testPrivateReservationAttributionMatchesSdkPublicationMetadata() async throws {
        let service = PrivatePaykitService()
        let publicKey = "pubkycontact"
        await service.setTestLocalInvoice(
            PrivatePaykitService.StoredInvoice(
                bolt11: "lnbc1private",
                paymentHash: "payment-hash",
                expiresAt: 123
            ),
            publicKey: publicKey
        )

        let endpoint = PublicPaykitService.Endpoint(
            methodId: .bitcoinLightningBolt11,
            value: "lnbc1private",
            min: nil,
            max: nil,
            rawPayload: #"{"value":"lnbc1private"}"#
        )

        let reservations = await service.reservations(
            from: [endpoint],
            publicKey: publicKey
        )
        XCTAssertEqual(reservations.count, 1)
        let reservation = try XCTUnwrap(reservations.first)
        let attribution = reservation.attribution

        XCTAssertEqual(attribution["type"], "private_paykit")
        XCTAssertEqual(attribution["counterparty"], publicKey)
        XCTAssertEqual(attribution["payment_hash"], "payment-hash")
    }

    func testPrivateReservationIdChangesWhenEndpointPayloadChanges() async throws {
        let service = PrivatePaykitService()
        let publicKey = "pubkycontact"
        let firstEndpoint = PublicPaykitService.Endpoint(
            methodId: .regtestOnchainP2wpkh,
            value: "bcrt1qfirst",
            min: nil,
            max: nil,
            rawPayload: #"{"value":"bcrt1qfirst"}"#
        )
        let secondEndpoint = PublicPaykitService.Endpoint(
            methodId: .regtestOnchainP2wpkh,
            value: "bcrt1qsecond",
            min: nil,
            max: nil,
            rawPayload: #"{"value":"bcrt1qsecond"}"#
        )

        let firstReservations = await service.reservations(
            from: [firstEndpoint],
            publicKey: publicKey
        )
        let repeatedReservations = await service.reservations(
            from: [firstEndpoint],
            publicKey: publicKey
        )
        let secondReservations = await service.reservations(
            from: [secondEndpoint],
            publicKey: publicKey
        )

        let firstReservation = try XCTUnwrap(firstReservations.first)
        let repeatedReservation = try XCTUnwrap(repeatedReservations.first)
        let secondReservation = try XCTUnwrap(secondReservations.first)

        XCTAssertEqual(firstReservation.reservationId, repeatedReservation.reservationId)
        XCTAssertNotEqual(firstReservation.reservationId, secondReservation.reservationId)
        XCTAssertTrue(firstReservation.reservationId.hasPrefix("\(publicKey):\(firstEndpoint.methodId.rawValue):"))
        XCTAssertLessThanOrEqual(firstReservation.reservationId.count, 128)
    }

    func testWalletBackupDecodesExistingPayloadWithoutPrivatePaykitFields() throws {
        let data = #"{"version":1,"createdAt":123,"transfers":[]}"#.data(using: .utf8)!
        let payload = try JSONDecoder().decode(WalletBackupV1.self, from: data)

        XCTAssertTrue(payload.transfers.isEmpty)
        XCTAssertNil(payload.privatePaykitHighestReservedReceiveIndexByAddressType)
        XCTAssertNil(payload.paykitSdkBackupState)
        XCTAssertNil(payload.watchOnlyAccounts)
        XCTAssertNil(payload.watchOnlyAccountAllocationState)
    }

    func testWalletBackupRoundTripsPrivateReservationCeilingAndSdkState() throws {
        let backup = WalletBackupV1(
            version: 1,
            createdAt: 123,
            transfers: [],
            privatePaykitHighestReservedReceiveIndexByAddressType: ["nativeSegwit": 5],
            paykitSdkBackupState: "AQID",
            watchOnlyAccounts: nil,
            watchOnlyAccountAllocationState: nil
        )

        let data = try JSONEncoder().encode(backup)
        let decoded = try JSONDecoder().decode(WalletBackupV1.self, from: data)

        XCTAssertEqual(decoded.version, backup.version)
        XCTAssertEqual(decoded.createdAt, backup.createdAt)
        XCTAssertTrue(decoded.transfers.isEmpty)
        XCTAssertEqual(decoded.privatePaykitHighestReservedReceiveIndexByAddressType, backup.privatePaykitHighestReservedReceiveIndexByAddressType)
        XCTAssertEqual(decoded.paykitSdkBackupState, backup.paykitSdkBackupState)
    }

    func testWalletRestoreRetainsRecoveryStateAndConsumedPaymentLists() async throws {
        let keys: [KeychainEntryType] = [.paykitRecoveryBackup, .paykitSession, .pubkySecretKey]
        let savedValues = try keys.map { try Keychain.load(key: $0) }
        addTeardownBlock {
            for (key, value) in zip(keys, savedValues) {
                if let value {
                    try Keychain.upsert(key: key, data: value)
                } else {
                    try Keychain.delete(key: key)
                }
            }
        }
        try Keychain.delete(key: .paykitSession)
        try Keychain.delete(key: .pubkySecretKey)
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let backup = PrivatePaykitService.Backup(
            sdkState: "opaque recovery state",
            consumedPrivatePaymentListVersions: [publicKey: 7]
        )
        let encoded = try String(decoding: JSONEncoder().encode(backup), as: UTF8.self)
        let service = PrivatePaykitService()

        try await service.restoreBackup(encoded)

        XCTAssertEqual(try Keychain.loadString(key: .paykitRecoveryBackup), backup.sdkState)
        let state = await service.testContactState(publicKey: publicKey)
        XCTAssertEqual(state?.consumedPrivatePaymentListVersion, 7)
        XCTAssertNil(try Keychain.load(key: .paykitSession))
        XCTAssertNil(try Keychain.load(key: .pubkySecretKey))
    }

    func testReservationStoreBacksUpRestoredCeiling() async throws {
        let suiteName = "PrivatePaykitServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PrivatePaykitAddressReservationStore(defaults: defaults)
        await store.restoreBackup(["nativeSegwit": 5])

        let snapshot = await store.backupSnapshot()
        XCTAssertEqual(snapshot?["nativeSegwit"], 5)
        XCTAssertNil(snapshot?["taproot"])
    }

    func testPrivatePaykitStateStoresOnlyAppOwnedAttributionState() throws {
        let publicKey = "pubkycontact"
        var contactState = PrivatePaykitService.ContactState()
        contactState.cachedResolvedEndpoints = [
            PrivatePaykitService.StoredPaymentEntry(
                methodId: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                endpointData: #"{"value":"lnbc1cached"}"#
            ),
        ]
        contactState.localInvoice = PrivatePaykitService.StoredInvoice(
            bolt11: "lnbc1local",
            paymentHash: "hash",
            expiresAt: 123
        )
        contactState.receivedInvoicePaymentHashes = ["received-hash"]
        contactState.hasPublishedPrivatePaymentList = true

        let state = PrivatePaykitService.PrivatePaykitState(contacts: [publicKey: contactState])
        let data = try JSONEncoder().encode(state)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("lnbc1cached"))
        XCTAssertTrue(json.contains("lnbc1local"))
        XCTAssertTrue(json.contains("received-hash"))
        let decoded = try JSONDecoder().decode(PrivatePaykitService.PrivatePaykitState.self, from: data)
        let decodedContact = try XCTUnwrap(decoded.contacts[publicKey])
        XCTAssertEqual(decodedContact.cachedResolvedEndpoints.first?.methodId, PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue)
        XCTAssertEqual(decodedContact.cachedResolvedEndpoints.first?.endpointData, #"{"value":"lnbc1cached"}"#)
        XCTAssertEqual(decodedContact.localInvoice?.bolt11, "lnbc1local")
        XCTAssertEqual(decodedContact.localInvoice?.paymentHash, "hash")
        XCTAssertEqual(decodedContact.localInvoice?.expiresAt, 123)
        XCTAssertEqual(decodedContact.receivedInvoicePaymentHashes, ["received-hash"])
        XCTAssertEqual(decodedContact.hasPublishedPrivatePaymentList, true)
    }

    func testConsumingPrivatePaymentListClearsEndpointsAndRejectsSameVersionForPair() async throws {
        let defaults = UserDefaults.standard
        let previousState = defaults.data(forKey: PrivatePaykitService.cacheStateKey)
        defaults.removeObject(forKey: PrivatePaykitService.cacheStateKey)
        defer {
            if let previousState {
                defaults.set(previousState, forKey: PrivatePaykitService.cacheStateKey)
            } else {
                defaults.removeObject(forKey: PrivatePaykitService.cacheStateKey)
            }
        }

        let service = PrivatePaykitService()
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let endpoint = PublicPaykitService.Endpoint(
            methodId: .bitcoinLightningLnurl,
            value: "lnurl1private",
            min: nil,
            max: nil,
            rawPayload: #"{"value":"lnurl1private"}"#
        )
        let context = PrivatePaykitPaymentContext(paymentAppsByEndpoint: [:], paymentListVersion: 7)
        let attemptId = UUID()

        await service.cacheResolvedEndpoints([endpoint], publicKey: publicKey)
        try await service.consumePrivatePaymentList(publicKey: publicKey, context: context, attemptId: attemptId)

        let contactState = await service.testContactState(publicKey: publicKey)
        XCTAssertTrue(contactState?.cachedResolvedEndpoints.isEmpty == true)
        XCTAssertEqual(contactState?.consumedPrivatePaymentListVersion, 7)

        do {
            try await service.consumePrivatePaymentList(publicKey: publicKey, context: context, attemptId: UUID())
            XCTFail("Expected the private payment list to be consumed only once")
        } catch PrivatePaykitError.paymentListAlreadyConsumed {
            // Expected.
        }
    }

    func testPaymentListConsumptionResolutionReleasesOnlyDefinitePreBroadcastFailures() async throws {
        let outcomes: [(PrivatePaymentListSendOutcome, UInt64)] = [
            (.succeeded, 7),
            (.uncertain, 7),
            (.definitePreBroadcastFailure, 4),
        ]
        for (outcome, expectedVersion) in outcomes {
            try await withIsolatedPrivatePaykitState { service in
                let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
                let previousContext = PrivatePaykitPaymentContext(paymentAppsByEndpoint: [:], paymentListVersion: 4)
                let attemptedContext = PrivatePaykitPaymentContext(paymentAppsByEndpoint: [:], paymentListVersion: 7)
                let previousAttemptId = UUID()
                try await service.consumePrivatePaymentList(publicKey: publicKey, context: previousContext, attemptId: previousAttemptId)
                try await service.resolvePrivatePaymentListConsumption(
                    publicKey: publicKey,
                    context: previousContext,
                    attemptId: previousAttemptId,
                    outcome: .succeeded
                )

                let attemptId = UUID()
                try await service.consumePrivatePaymentList(publicKey: publicKey, context: attemptedContext, attemptId: attemptId)
                try await service.resolvePrivatePaymentListConsumption(
                    publicKey: publicKey,
                    context: attemptedContext,
                    attemptId: attemptId,
                    outcome: outcome
                )

                let contactState = await service.testContactState(publicKey: publicKey)
                XCTAssertEqual(contactState?.consumedPrivatePaymentListVersion, expectedVersion)

                if outcome == .definitePreBroadcastFailure {
                    try await service.consumePrivatePaymentList(
                        publicKey: publicKey,
                        context: attemptedContext,
                        attemptId: UUID()
                    )
                    try await service.resolvePrivatePaymentListConsumption(
                        publicKey: publicKey,
                        context: attemptedContext,
                        attemptId: attemptId,
                        outcome: .definitePreBroadcastFailure
                    )
                    let stateAfterDelayedRelease = await service.testContactState(publicKey: publicKey)
                    XCTAssertEqual(stateAfterDelayedRelease?.consumedPrivatePaymentListVersion, 7)
                } else {
                    do {
                        try await service.consumePrivatePaymentList(
                            publicKey: publicKey,
                            context: attemptedContext,
                            attemptId: UUID()
                        )
                        XCTFail("A retained payment list version must not be reusable")
                    } catch PrivatePaykitError.paymentListAlreadyConsumed {
                        // Expected.
                    }
                }
            }
        }
    }

    func testStalePaymentListReleaseDoesNotUndoNewerConsumption() async throws {
        try await withIsolatedPrivatePaykitState { service in
            let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
            let olderContext = PrivatePaykitPaymentContext(paymentAppsByEndpoint: [:], paymentListVersion: 7)
            let newerContext = PrivatePaykitPaymentContext(paymentAppsByEndpoint: [:], paymentListVersion: 8)
            let olderAttemptId = UUID()
            let newerAttemptId = UUID()

            try await service.consumePrivatePaymentList(publicKey: publicKey, context: olderContext, attemptId: olderAttemptId)
            try await service.consumePrivatePaymentList(publicKey: publicKey, context: newerContext, attemptId: newerAttemptId)
            try await service.resolvePrivatePaymentListConsumption(
                publicKey: publicKey,
                context: olderContext,
                attemptId: olderAttemptId,
                outcome: .definitePreBroadcastFailure
            )
            let stateAfterStaleRelease = await service.testContactState(publicKey: publicKey)
            XCTAssertEqual(stateAfterStaleRelease?.consumedPrivatePaymentListVersion, 8)

            try await service.resolvePrivatePaymentListConsumption(
                publicKey: publicKey,
                context: newerContext,
                attemptId: newerAttemptId,
                outcome: .definitePreBroadcastFailure
            )
            let stateAfterCurrentRelease = await service.testContactState(publicKey: publicKey)
            XCTAssertEqual(stateAfterCurrentRelease?.consumedPrivatePaymentListVersion, 7)
        }
    }

    func testClearingContactStatePreservesConsumedPrivatePaymentListVersions() async throws {
        let defaults = UserDefaults.standard
        let previousState = defaults.data(forKey: PrivatePaykitService.cacheStateKey)
        defaults.removeObject(forKey: PrivatePaykitService.cacheStateKey)
        defer {
            if let previousState {
                defaults.set(previousState, forKey: PrivatePaykitService.cacheStateKey)
            } else {
                defaults.removeObject(forKey: PrivatePaykitService.cacheStateKey)
            }
        }

        let service = PrivatePaykitService()
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let endpoint = PublicPaykitService.Endpoint(
            methodId: .bitcoinLightningLnurl,
            value: "lnurl1private",
            min: nil,
            max: nil,
            rawPayload: #"{"value":"lnurl1private"}"#
        )
        let context = PrivatePaykitPaymentContext(paymentAppsByEndpoint: [:], paymentListVersion: 9)

        await service.cacheResolvedEndpoints([endpoint], publicKey: publicKey)
        try await service.consumePrivatePaymentList(publicKey: publicKey, context: context, attemptId: UUID())
        await service.clearContactState(publicKey: publicKey)

        let contactState = await service.testContactState(publicKey: publicKey)
        XCTAssertEqual(contactState?.consumedPrivatePaymentListVersion, 9)
        XCTAssertFalse(contactState?.hasContactOwnedCacheState == true)
    }

    func testPrivatePaymentRecoveryKeepsActiveRetryWhenContactsAreAdded() async {
        let service = PrivatePaykitService()
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let otherPublicKey = "pubky1rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"

        await service.schedulePrivatePaymentRecovery(for: publicKey)
        let generation = await service.pendingMessageDrainRetryGeneration
        await service.schedulePrivatePaymentRecovery(for: publicKey)
        await service.schedulePrivatePaymentRecovery(for: otherPublicKey)

        let retryKeys = await service.testPendingMessageDrainRetryKeys()
        let repeatedGeneration = await service.pendingMessageDrainRetryGeneration
        XCTAssertEqual(retryKeys, [publicKey, otherPublicKey])
        XCTAssertEqual(repeatedGeneration, generation)
        await service.clearTestPendingMessageDrainRetries()

        await service.schedulePrivatePaymentRecovery(for: otherPublicKey)
        let restartedGeneration = await service.pendingMessageDrainRetryGeneration
        XCTAssertGreaterThan(restartedGeneration, generation)
        await service.clearTestPendingMessageDrainRetries()
    }

    func testPublishedEndpointCleanupPreservesFailedContactStateAndRetryMarker() async {
        let successfulPublicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let failedPublicKey = "pubky1rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let previousPendingKeys = PrivatePaykitService.pendingDeletedContactCleanupKeys()
        PrivatePaykitService.clearDeletedContactCleanupPending()
        defer {
            PrivatePaykitService.clearDeletedContactCleanupPending()
            PrivatePaykitService.markDeletedContactCleanupPending(Array(previousPendingKeys))
        }

        let service = PrivatePaykitService()
        var contactState = PrivatePaykitService.ContactState()
        contactState.cachedResolvedEndpoints = [
            PrivatePaykitService.StoredPaymentEntry(
                methodId: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                endpointData: #"{"value":"lnbc1private"}"#
            ),
        ]
        contactState.localInvoice = PrivatePaykitService.StoredInvoice(
            bolt11: "lnbc1private",
            paymentHash: "payment-hash",
            expiresAt: 123
        )
        contactState.hasPublishedPrivatePaymentList = true
        await service.setTestContactState(contactState, publicKey: successfulPublicKey)
        await service.setTestContactState(contactState, publicKey: failedPublicKey)
        PrivatePaykitService.markDeletedContactCleanupPending([successfulPublicKey, failedPublicKey])

        let didChangeState = await service.applyPublishedEndpointCleanupResults(
            successfulPublicKeys: [successfulPublicKey],
            failedPublicKeys: [failedPublicKey]
        )

        XCTAssertTrue(didChangeState)
        let successfulContactState = await service.testContactState(publicKey: successfulPublicKey)
        let failedContactState = await service.testContactState(publicKey: failedPublicKey)
        XCTAssertNil(successfulContactState)
        XCTAssertNotNil(failedContactState)
        XCTAssertEqual(PrivatePaykitService.pendingDeletedContactCleanupKeys(), [failedPublicKey])
    }

    @MainActor
    func testPrunePreservesContactReaddedWhileWaitingForPublication() async throws {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        PrivatePaykitService.clearDeletedContactCleanupPending()
        let key = "pubky" + String(repeating: "y", count: 52)
        let service = PrivatePaykitService()
        let contacts = ContactsManager()
        var state = PrivatePaykitService.ContactState()
        state.hasPublishedPrivatePaymentList = true
        await service.setTestContactState(state, publicKey: key)
        await service.setBackgroundWorkPaused(true)
        let locked = expectation(description: "Publication lock held")
        let waiting = expectation(description: "Prune has selected its contacts")
        let (release, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let publication = Task {
            try await service.withPublicationLock {
                locked.fulfill()
                for await _ in release {}
            }
        }
        await fulfillment(of: [locked], timeout: 2)
        let snapshot = contacts.savedContactsSnapshot()
        var checks = 0
        let prune = Task {
            await service.pruneUnsavedContactState(savedPublicKeys: snapshot.publicKeys, isSessionCurrent: {
                checks += 1
                if checks == 2 { waiting.fulfill() }
                return snapshot.isCurrent()
            })
        }
        await fulfillment(of: [waiting], timeout: 2)
        contacts.contacts = [.init(publicKey: key, profile: Bitkit.PubkyProfile.placeholder(publicKey: key))]
        _ = await service.rememberSavedContacts([key], replacing: false)
        await service.scheduleExplicitContactLink(publicKey: key, identity: "owner")
        let retry = await service.pendingMessageDrainRetries[key]
        continuation.finish()
        try await publication.value
        await prune.value
        let retained = await service.testContactState(publicKey: key)
        let retainedRetry = await service.pendingMessageDrainRetries[key]
        XCTAssertTrue(retained?.hasPublishedPrivatePaymentList == true)
        XCTAssertNotNil(retry)
        XCTAssertEqual(retainedRetry?.id, retry?.id)
        await service.invalidateContactPreparation()
        await service.setBackgroundWorkPaused(false)
    }

    func testGuardedCleanupChecksMembershipAndGenerationAfterAdmittedWithdrawal() async throws {
        let key = "pubky" + String(repeating: "y", count: 52)
        for change in ["none", "readd", "identity"] {
            let service = PrivatePaykitService()
            var state = PrivatePaykitService.ContactState()
            state.hasPublishedPrivatePaymentList = true
            await service.setTestContactState(state, publicKey: key)
            let admitted = expectation(description: "Withdrawal admitted")
            let (finish, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            let operations = PrivatePaykitService.EndpointCleanupOperations(
                linkedPeers: { [] }, clearPaymentLists: { _ in
                    admitted.fulfill()
                    for await _ in finish {}
                    XCTAssertFalse(Task.isCancelled)
                    return nil
                }, drainMessages: { _ in }, pendingDrainKeys: { _ in [] }, syncApp: {}
            )
            let cleanup = Task {
                try await service.removePublishedEndpoints(for: [key], isSessionCurrent: { true }, operations: operations)
            }
            await fulfillment(of: [admitted], timeout: 2)
            if change == "readd" { _ = await service.rememberSavedContacts([key], replacing: false) }
            if change == "identity" { await service.invalidateContactPreparation() }
            continuation.finish()
            let result = await cleanup.result
            let retained = await service.testContactState(publicKey: key)
            if change == "none" {
                try result.get()
                XCTAssertNil(retained)
            } else {
                if case .success = result { XCTFail("Superseded cleanup must not clear contact state") }
                XCTAssertTrue(retained?.hasPublishedPrivatePaymentList == true)
            }
            try await service.removePublishedEndpoints(isSessionCurrent: { true }, operations: .init(
                linkedPeers: { [] }, clearPaymentLists: { _ in nil },
                drainMessages: { _ in }, pendingDrainKeys: { _ in [] }, syncApp: {}
            ))
            let afterSharingOff = await service.testContactState(publicKey: key)
            XCTAssertNil(afterSharingOff)
        }
    }

    @MainActor
    func testGuardedCleanupPreservesCacheUpdatedDuringFinalSessionCheck() async throws {
        let key = "pubky" + String(repeating: "y", count: 52)
        let service = PrivatePaykitService()
        var state = PrivatePaykitService.ContactState()
        state.hasPublishedPrivatePaymentList = true
        await service.setTestContactState(state, publicKey: key)
        let endpoint = PublicPaykitService.Endpoint(
            methodId: .bitcoinLightningLnurl, value: "lnurl1updated", min: nil, max: nil,
            rawPayload: #"{"value":"lnurl1updated"}"#
        )
        var withdrawalCompleted = false
        var cacheUpdate: Task<Void, Never>?
        let operations = PrivatePaykitService.EndpointCleanupOperations(
            linkedPeers: { [] }, clearPaymentLists: { _ in
                await MainActor.run { withdrawalCompleted = true }
                return nil
            }, drainMessages: { _ in }, pendingDrainKeys: { _ in [] }, syncApp: {}
        )
        do {
            try await service.removePublishedEndpoints(for: [key], isSessionCurrent: {
                if withdrawalCompleted, cacheUpdate == nil {
                    let updated = self.expectation(description: "Endpoint cache updated during session check")
                    cacheUpdate = Task.detached {
                        await service.cacheResolvedEndpoints([endpoint], publicKey: key)
                        updated.fulfill()
                    }
                    // Complete the actor write while cleanup is suspended on this synchronous MainActor predicate.
                    XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed)
                }
                return true
            }, operations: operations)
            XCTFail("Cleanup must defer when endpoint state changes during its final session check")
        } catch PrivatePaykitError.privateUnavailable {}
        await cacheUpdate?.value
        XCTAssertNotNil(cacheUpdate)
        let retained = await service.testContactState(publicKey: key)
        XCTAssertEqual(retained?.cachedResolvedEndpoints.first?.endpointData, endpoint.rawPayload)
        XCTAssertTrue(retained?.hasPublishedPrivatePaymentList == true)
    }

    func testCleanupFailuresKeepRegistryReconciliationPending() async throws {
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        UserDefaults.standard.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
        for failureStage in ["lookup", "withdraw", "queue", "pending", "registry"] {
            let service = PrivatePaykitService()
            var contactState = PrivatePaykitService.ContactState()
            contactState.hasPublishedPrivatePaymentList = true
            await service.setTestContactState(contactState, publicKey: publicKey)
            PrivatePaykitService.markDeletedContactCleanupPending([publicKey])
            PublicPaykitService.setCleanupPending(false)
            var shouldFail = true
            var registryUpdates = 0
            let operations = PrivatePaykitService.EndpointCleanupOperations(
                linkedPeers: {
                    if shouldFail, failureStage == "lookup" { throw PrivatePaykitError.privateUnavailable }
                    return []
                },
                clearPaymentLists: { _ in
                    if shouldFail, failureStage == "withdraw" { throw PrivatePaykitError.privateUnavailable }
                    if shouldFail, failureStage == "queue" {
                        return PrivatePaymentListDeliveryReport(
                            queued: [], cleared: [],
                            failedToQueue: [PrivatePaymentListSyncChange(counterparty: publicKey, outboundMessageId: nil, error: nil)],
                            failedToDeliver: []
                        )
                    }
                    return PrivatePaymentListDeliveryReport(
                        queued: [], cleared: [.init(counterparty: publicKey, outboundMessageId: 1, error: nil)],
                        failedToQueue: [], failedToDeliver: []
                    )
                },
                drainMessages: { keys in
                    XCTAssertTrue(shouldFail && failureStage == "pending")
                    XCTAssertEqual(keys, [publicKey])
                },
                pendingDrainKeys: { _ in shouldFail && failureStage == "pending" ? [publicKey] : [] },
                syncApp: {
                    registryUpdates += 1
                    if shouldFail, failureStage == "registry" { throw PrivatePaykitError.privateUnavailable }
                }
            )

            do {
                try await service.removePublishedEndpoints(for: [publicKey], operations: operations)
                XCTFail("Expected \(failureStage) failure")
            } catch {
                XCTAssertTrue(PublicPaykitService.isCleanupPending)
            }
            XCTAssertEqual(registryUpdates, failureStage == "registry" ? 1 : 0)
            let retainedState = await service.testContactState(publicKey: publicKey)
            XCTAssertEqual(retainedState?.hasPublishedPrivatePaymentList == true, failureStage != "registry")

            shouldFail = false
            try await service.removePublishedEndpoints(for: [publicKey], operations: operations)
            let clearedState = await service.testContactState(publicKey: publicKey)
            XCTAssertFalse(clearedState?.hasPublishedPrivatePaymentList == true)
            XCTAssertFalse(PrivatePaykitService.pendingDeletedContactCleanupKeys().contains(publicKey))
            XCTAssertEqual(registryUpdates, failureStage == "registry" ? 2 : 1)
        }
    }

    func testFullCleanupFindsRemotePeersAndRetainsFailedDiscovery() async throws {
        UserDefaults.standard.removeObject(forKey: PrivatePaykitService.cacheStateKey)
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let peer = LinkedPeerRecord(
            counterparty: publicKey, state: .linked,
            lastSyncAt: nil, lastPrivateReceiveAt: nil, failureCount: 0,
            localRecoveryAttemptId: nil, localRecoveryMarkerCreatedAt: nil, localRecoveryMarkerLastError: nil,
            remoteRecoveryAttemptId: nil, remoteRecoveryMarkerObservedAt: nil
        )
        var linkingPeer = peer
        linkingPeer.counterparty = "pubky5rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        linkingPeer.state = .linking
        var recoveringPeer = peer
        recoveringPeer.counterparty = "pubky6rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        recoveringPeer.state = .recoveryRequired
        let expectedKeys = [publicKey, linkingPeer.counterparty, recoveringPeer.counterparty]
        let service = PrivatePaykitService()
        var failLookup = true
        var delivered = false
        var cleared = [String]()
        var registryUpdates = 0
        let operations = PrivatePaykitService.EndpointCleanupOperations(
            linkedPeers: {
                if failLookup { throw PrivatePaykitError.privateUnavailable }
                return [peer, linkingPeer, recoveringPeer]
            },
            clearPaymentLists: {
                XCTAssertEqual(Set($0), Set(expectedKeys))
                cleared.append(contentsOf: $0)
                return PrivatePaymentListDeliveryReport(
                    queued: [], cleared: $0.map { .init(counterparty: $0, outboundMessageId: 1, error: nil) },
                    failedToQueue: [], failedToDeliver: []
                )
            },
            drainMessages: { XCTAssertEqual(Set($0), Set(expectedKeys.dropFirst())) },
            pendingDrainKeys: {
                PrivatePaykitService.pendingPrivateMessageDrainKeys(
                    Set($0),
                    linkedPeers: Dictionary(uniqueKeysWithValues: [peer, linkingPeer, recoveringPeer].map {
                        ($0.counterparty, delivered ? .linked : $0.state)
                    }),
                    pendingOutbound: []
                )
            },
            syncApp: {
                XCTAssertEqual(Set(cleared), Set(expectedKeys))
                registryUpdates += 1
            }
        )

        await service.setBackgroundWorkPaused(true)
        do {
            try await service.removePublishedEndpoints(operations: operations)
            XCTFail("Failed discovery must keep cleanup pending")
        } catch {
            XCTAssertTrue(PublicPaykitService.isCleanupPending)
        }
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertEqual(registryUpdates, 0)
        failLookup = false
        do {
            try await service.removePublishedEndpoints(operations: operations)
            XCTFail("Pending recovery must keep cleanup pending")
        } catch {
            XCTAssertTrue(PublicPaykitService.isCleanupPending)
        }
        XCTAssertEqual(registryUpdates, 0)
        delivered = true
        try await service.removePublishedEndpoints(operations: operations)
        XCTAssertEqual(cleared.count, expectedKeys.count * 2)
        XCTAssertEqual(registryUpdates, 1)
    }

    func testBatchCleanupRetainsOnlyFailedContacts() async throws {
        let failed = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let successful = "pubky5rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        for failQueue in [true, false] {
            let service = PrivatePaykitService()
            var contact = PrivatePaykitService.ContactState()
            contact.hasPublishedPrivatePaymentList = true
            for key in [failed, successful] {
                await service.setTestContactState(contact, publicKey: key)
            }
            PrivatePaykitService.markDeletedContactCleanupPending([failed, successful])
            var batches = 0
            do {
                try await service.removePublishedEndpoints(for: [failed, successful], operations: .init(
                    linkedPeers: { [] },
                    clearPaymentLists: { keys in
                        batches += 1
                        XCTAssertEqual(Set(keys), [failed, successful])
                        return .init(
                            queued: [], cleared: [.init(counterparty: successful, outboundMessageId: 1, error: nil)],
                            failedToQueue: failQueue ? [.init(counterparty: failed, outboundMessageId: nil, error: nil)] : [],
                            failedToDeliver: failQueue ? [] : [.init(
                                counterparty: failed, outboundMessageId: 2, reservationId: nil,
                                error: CleanupDeliveryError(noPointer: .init())
                            )]
                        )
                    },
                    drainMessages: { _ in XCTFail("Delivered withdrawal needs no drain") },
                    pendingDrainKeys: { _ in [] },
                    syncApp: { XCTFail("Failed withdrawal must retain the private capability") }
                ))
                XCTFail("Expected partial failure")
            } catch {}
            XCTAssertEqual(batches, 1)
            let failedState = await service.testContactState(publicKey: failed)
            let successfulState = await service.testContactState(publicKey: successful)
            XCTAssertTrue(failedState?.hasPublishedPrivatePaymentList == true)
            XCTAssertNil(successfulState)
            XCTAssertTrue(PrivatePaykitService.pendingDeletedContactCleanupKeys().contains(failed))
            XCTAssertFalse(PrivatePaykitService.pendingDeletedContactCleanupKeys().contains(successful))
        }
    }

    func testCleanupSkipsNeverLinkedContactsWithoutPublishedDetails() async {
        let service = PrivatePaykitService()
        var publishedState = PrivatePaykitService.ContactState()
        publishedState.hasPublishedPrivatePaymentList = true
        await service.setTestContactState(publishedState, publicKey: "published")

        let keys = await service.privatePaymentListCleanupKeys(
            ["pubky-only", "linked", "published"],
            linkedPublicKeys: ["linked"]
        )

        XCTAssertEqual(keys, ["linked", "published"])
    }

    func testImmediatePublicationSkipsContactsWithoutPaykitOrUnavailableLinks() async {
        for linkError in [
            PaykitError.NotFound(code: "not_found", context: "No App Registry"),
            PaykitError.Transport(code: "offline", context: "Unavailable homeserver"),
        ] {
            let service = PrivatePaykitService()
            _ = await service.rememberSavedContacts(["pubky1rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"], replacing: true)
            let operations = PrivatePaykitService.EndpointPublicationOperations(
                currentPublicKey: { "pubkylocal" },
                ensureLink: { _ in throw linkError },
                buildEndpoints: { _ in
                    XCTFail("An unsupported contact should not reserve wallet addresses")
                    return []
                },
                syncPaymentLists: { _ in
                    XCTFail("An unsupported contact should not receive a private list")
                    return PrivatePaymentListDeliveryReport(queued: [], cleared: [], failedToQueue: [], failedToDeliver: [])
                }
            )

            let error = await service.syncLocalEndpointPublication(
                for: ["pubky1rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"],
                reason: "test",
                requireImmediatePublication: true,
                operations: operations
            )

            XCTAssertNil(error)
        }
    }

    func testImmediatePublicationContinuesAfterEndpointPreparationFailure() async throws {
        let failedPublicKey = "pubky1rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let successfulPublicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let preparationError = NSError(domain: "PrivatePaykitServiceTests", code: 1)
        let endpoint = PublicPaykitService.Endpoint(
            methodId: .regtestOnchainP2wpkh,
            value: "bcrt1qendpoint",
            min: nil,
            max: nil,
            rawPayload: #"{"value":"bcrt1qendpoint"}"#
        )
        var syncedUpdates = [PrivatePaymentListReservationUpdateInput]()
        let operations = PrivatePaykitService.EndpointPublicationOperations(
            currentPublicKey: { "pubkylocal" },
            ensureLink: { _ in .linked },
            buildEndpoints: { publicKey in
                if publicKey == failedPublicKey { throw preparationError }
                XCTAssertEqual(publicKey, successfulPublicKey)
                return [endpoint]
            },
            syncPaymentLists: { updates in
                syncedUpdates = updates
                return PrivatePaymentListDeliveryReport(
                    queued: [],
                    cleared: [],
                    failedToQueue: [],
                    failedToDeliver: []
                )
            }
        )
        let service = PrivatePaykitService()

        _ = await service.rememberSavedContacts([failedPublicKey, successfulPublicKey], replacing: true)
        await service.setBackgroundWorkPaused(true)
        let error = await service.syncLocalEndpointPublication(
            for: [failedPublicKey, successfulPublicKey],
            reason: "test",
            requireImmediatePublication: true,
            operations: operations
        )

        XCTAssertNotNil(error)
        XCTAssertEqual(syncedUpdates.count, 1)
        let update = try XCTUnwrap(syncedUpdates.first)
        XCTAssertEqual(update.counterparty, successfulPublicKey)
        XCTAssertFalse(update.reservations.isEmpty)
    }

    func testFailedPublicationRetainsPendingLinksOnlyForCurrentIdentity() async {
        let publicKey = "pubky1rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        for changesIdentity in [false, true] {
            var identity = "pubkylocal"
            let service = PrivatePaykitService()
            _ = await service.rememberSavedContacts([publicKey], replacing: true)
            let operations = PrivatePaykitService.EndpointPublicationOperations(
                currentPublicKey: { identity },
                ensureLink: { _ in .linking },
                buildEndpoints: { _ in
                    [PublicPaykitService.Endpoint(
                        methodId: .regtestOnchainP2wpkh,
                        value: "bcrt1qendpoint",
                        min: nil,
                        max: nil,
                        rawPayload: #"{"value":"bcrt1qendpoint"}"#
                    )]
                },
                syncPaymentLists: { _ in
                    if changesIdentity { identity = "pubkyother" }
                    throw PaykitError.Transport(code: "offline", context: "Unavailable homeserver")
                }
            )

            let error = await service.syncLocalEndpointPublication(
                for: [publicKey], reason: "test", requireImmediatePublication: true, operations: operations
            )

            XCTAssertNotNil(error)
            let pending = await service.testPendingMessageDrainRetryKeys()
            XCTAssertEqual(pending, changesIdentity ? [] : [publicKey])
            await service.clearTestPendingMessageDrainRetries()
        }
    }

    func testDeferredPublicationRetainsEndpointPreparationFailureForRetry() async {
        let publicKey = "pubky1rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let preparationError = NSError(domain: "PrivatePaykitServiceTests", code: 1)
        let operations = PrivatePaykitService.EndpointPublicationOperations(
            currentPublicKey: { "pubkylocal" },
            ensureLink: { _ in .linked },
            buildEndpoints: { _ in throw preparationError },
            syncPaymentLists: { _ in
                XCTFail("No payment list should be synced")
                return PrivatePaymentListDeliveryReport(
                    queued: [],
                    cleared: [],
                    failedToQueue: [],
                    failedToDeliver: []
                )
            }
        )
        let service = PrivatePaykitService()

        _ = await service.rememberSavedContacts([publicKey], replacing: true)
        let error = await service.syncLocalEndpointPublication(
            for: [publicKey],
            reason: "test",
            requireImmediatePublication: false,
            operations: operations
        )

        XCTAssertNil(error)
    }

    func testBackgroundPreparationCoalescesRepeatedRequests() async {
        let service = PrivatePaykitService()
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        _ = await service.rememberSavedContacts([publicKey], replacing: true)
        let started = expectation(description: "Preparation started")
        let (resume, continuation) = AsyncStream<Void>.makeStream()
        var preparedKeys = [[String]]()
        let operation: ([String], Bool) async -> Void = { keys, _ in
            preparedKeys.append(keys)
            started.fulfill()
            for await _ in resume {
                break
            }
        }

        await service.scheduleContactPreparation([publicKey], operation: operation)
        await fulfillment(of: [started], timeout: 2)
        for _ in 0 ..< 3 {
            await service.scheduleContactPreparation([publicKey], operation: operation)
        }
        let task = await service.preparationTask
        continuation.yield(())
        continuation.finish()
        await task?.value

        XCTAssertEqual(preparedKeys, [[publicKey]])
    }

    func testProfileDeletionDropsPreparationAndAllowsNewWorkAfterDeletionEnds() async {
        let service = PrivatePaykitService()
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        _ = await service.rememberSavedContacts([publicKey], replacing: true)
        await service.beginProfileDeletion()
        await service.scheduleContactPreparation([publicKey]) { _, _ in
            XCTFail("Profile deletion must not enqueue preparation")
        }
        let deletionTask = await service.preparationTask
        XCTAssertNil(deletionTask)

        await service.endProfileDeletion()
        let resumedTask = await service.preparationTask
        XCTAssertNil(resumedTask)
        let prepared = expectation(description: "New preparation starts")
        await service.scheduleContactPreparation([publicKey]) { _, _ in prepared.fulfill() }
        await fulfillment(of: [prepared], timeout: 2)
    }

    func testBackgroundPreparationRetainsCoalescedKeysAndForceRefreshUntilResumed() async throws {
        let service = PrivatePaykitService()
        let keys = [String(repeating: "y", count: 52), String(repeating: "o", count: 52)].map { "pubky" + $0 }
        _ = await service.rememberSavedContacts(keys, replacing: true)
        await service.setBackgroundWorkPaused(true)
        var batches: [[String]] = []
        let operation: ([String], Bool) async -> Void = { keys, forceRefresh in
            XCTAssertTrue(forceRefresh)
            batches.append(keys)
        }
        await service.scheduleContactPreparation([keys[0]], operation: operation)
        await service.scheduleContactPreparation(keys, forceRefreshLightning: true, operation: operation)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(batches.isEmpty)
        let pending = await service.pendingPreparationKeys
        XCTAssertEqual(pending, Set(keys))
        let task = await service.preparationTask
        XCTAssertEqual(task?.isCancelled, false)

        await service.setBackgroundWorkPaused(false)
        await task?.value
        XCTAssertEqual(batches, [keys.sorted()])
    }

    func testInvalidationDiscardsPausedPreparationWithoutLosingNewWork() async throws {
        let service = PrivatePaykitService()
        let key = "pubky" + String(repeating: "y", count: 52)
        _ = await service.rememberSavedContacts([key], replacing: true)
        await service.setBackgroundWorkPaused(true)
        await service.scheduleContactPreparation([key]) { _, _ in XCTFail("Invalidated preparation must not run") }
        try await Task.sleep(for: .milliseconds(50))
        await service.invalidateContactPreparation()
        var prepared: [String] = []
        await service.scheduleContactPreparation([key]) { keys, _ in prepared = keys }
        await service.setBackgroundWorkPaused(false)
        try await service.awaitContactPreparation()
        XCTAssertEqual(prepared, [key])
    }

    func testBackgroundPauseDoesNotSplitAnAdmittedPublicationBatch() async {
        let service = PrivatePaykitService()
        let key = "pubky" + String(repeating: "y", count: 52)
        _ = await service.rememberSavedContacts([key], replacing: true)
        var published = false
        let operations = PrivatePaykitService.EndpointPublicationOperations(
            currentPublicKey: { "local" },
            ensureLink: { _ in .linked },
            buildEndpoints: { _ in
                await service.setBackgroundWorkPaused(true)
                return []
            },
            syncPaymentLists: { updates in
                XCTAssertFalse(Task.isCancelled)
                XCTAssertEqual(updates.map(\.counterparty), [key])
                published = true
                return PrivatePaymentListDeliveryReport(queued: [], cleared: [], failedToQueue: [], failedToDeliver: [])
            }
        )
        _ = await service.syncLocalEndpointPublication(
            for: [key], reason: "test", requireImmediatePublication: false, operations: operations
        )
        XCTAssertTrue(published)
    }

    func testBackgroundPreparationWaitsBeforeReadingPeersAfterTransportFailure() async throws {
        for invalidate in [false, true] {
            let service = PrivatePaykitService()
            let key = "pubky" + String(repeating: "y", count: 52)
            _ = await service.rememberSavedContacts([key], replacing: true)
            let failed = expectation(description: "Link failed while backgrounded")
            var reads = 0
            let operations = PrivatePaykitService.EndpointPublicationOperations(
                currentPublicKey: { "local" },
                ensureLink: { _ in
                    await service.setBackgroundWorkPaused(true)
                    failed.fulfill()
                    throw PaykitError.Transport(code: "offline", context: "Unavailable homeserver")
                },
                buildEndpoints: { _ in XCTFail("No prepared link"); return [] },
                syncPaymentLists: { _ in XCTFail("No prepared link"); return .init(queued: [], cleared: [], failedToQueue: [], failedToDeliver: []) },
                linkedPeers: { reads += 1; return [] }
            )
            let task = Task {
                await service.syncLocalEndpointPublication(
                    for: [key], reason: "test", requireImmediatePublication: false, operations: operations
                )
            }
            await fulfillment(of: [failed], timeout: 2)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(reads, 1)
            if invalidate { await service.invalidateContactPreparation() }
            await service.setBackgroundWorkPaused(false)
            _ = await task.value
            XCTAssertEqual(reads, invalidate ? 1 : 2)
            await service.invalidateContactPreparation()
        }
    }

    func testBackgroundDrainFinishesActiveCallThenWaitsAtEachBoundary() async throws {
        let order = ["initialPeers", "link", "link", "outbound", "send", "send", "peers", "receive", "receive"]
        for stage in ["initialPeers", "link", "outbound", "send", "peers", "receive"] {
            for outcome in ["resume", "invalidate", "cancel"] {
                let service = PrivatePaykitService()
                let started = expectation(description: "Active \(stage) started")
                let (gate, release) = AsyncStream<Void>.makeStream()
                defer { release.finish() }
                var events: [String] = []
                var paused = false
                let record: (String) async -> Void = { event in
                    events.append(event)
                    if event == stage, !paused {
                        paused = true
                        started.fulfill()
                        for await _ in gate {}
                        XCTAssertFalse(Task.isCancelled)
                    }
                }
                let task = Task {
                    await service.drainPendingPrivateMessages(
                        reason: "test", advancing: ["first", "second"], isBackgroundWork: true, operations: .init(
                            ensureLink: { _ in await record("link") },
                            pendingOutbound: { await record("outbound"); return ["first", "second"] },
                            linkedPeers: {
                                let initial = events.isEmpty
                                await record(initial ? "initialPeers" : "peers")
                                return initial ? [] : [self.drainPeer("first"), self.drainPeer("second")]
                            },
                            processPending: { _ in await record("send") },
                            receive: { _ in await record("receive") }
                        )
                    )
                }
                await fulfillment(of: [started], timeout: 2)
                await service.setBackgroundWorkPaused(true)
                XCTAssertFalse(task.isCancelled)
                release.finish()
                try await Task.sleep(for: .milliseconds(50))
                let prefix = try Array(order.prefix(through: XCTUnwrap(order.firstIndex(of: stage))))
                XCTAssertEqual(events, prefix, "\(stage): \(outcome)")
                let waiters = await service.backgroundWorkWaiters.count
                XCTAssertEqual(waiters, 1)
                switch outcome {
                case "resume": await service.setBackgroundWorkPaused(false)
                case "invalidate": await service.invalidateContactPreparation()
                default: task.cancel()
                }
                await task.value
                XCTAssertEqual(events, outcome == "resume" ? order : prefix)
                let remainingWaiters = await service.backgroundWorkWaiters.count
                XCTAssertEqual(remainingWaiters, 0)
            }
        }
    }

    func testExplicitDrainDoesNotWaitForBackgroundPreparation() async {
        let service = PrivatePaykitService()
        await service.setBackgroundWorkPaused(true)
        var received = false
        await service.drainPendingPrivateMessages(reason: "cleanup", advancing: ["peer"], operations: .init(
            ensureLink: { _ in XCTFail("Peer is already linked") },
            pendingOutbound: { [] },
            linkedPeers: { [self.drainPeer("peer")] },
            processPending: { _ in XCTFail("No pending messages") },
            receive: { _ in received = true }
        ))
        XCTAssertTrue(received)
    }

    func testBackgroundPauseRetainsRetryTaskKeysAndGeneration() async throws {
        let service = PrivatePaykitService()
        let key = "pubky" + String(repeating: "y", count: 52)
        await service.setBackgroundWorkPaused(true)
        await service.schedulePrivatePaymentRecovery(for: key)
        let generation = await service.pendingMessageDrainRetryGeneration
        try await Task.sleep(for: .milliseconds(1100))
        let keys = await service.pendingMessageDrainRetryKeys
        let task = await service.pendingMessageDrainRetryTask
        let currentGeneration = await service.pendingMessageDrainRetryGeneration
        XCTAssertEqual(keys, [key])
        XCTAssertEqual(currentGeneration, generation)
        XCTAssertEqual(task?.isCancelled, false)
        await service.invalidateContactPreparation()
        await task?.value
        let invalidatedKeys = await service.pendingMessageDrainRetryKeys
        XCTAssertTrue(invalidatedKeys.isEmpty)
    }

    func testResumingPublicationRetainsCleanupOnlyWhenRestorationFails() async {
        let service = PrivatePaykitService()
        for fails in [false, true] {
            PrivatePaykitService.setContactSharingCleanupPending(true)
            let error = await service.resumeEndpointPublication {
                XCTAssertFalse(UserDefaults.standard.bool(forKey: PrivatePaykitService.cleanupPendingKey))
                return fails ? PrivatePaykitError.privateUnavailable : nil
            }
            XCTAssertEqual(error != nil, fails)
            XCTAssertEqual(UserDefaults.standard.bool(forKey: PrivatePaykitService.cleanupPendingKey), fails)
        }
    }

    func testInvalidatedRestorationDoesNotRestoreCleanupMarker() async {
        let service = PrivatePaykitService()
        PrivatePaykitService.setContactSharingCleanupPending(true)

        let error = await service.resumeEndpointPublication {
            await service.invalidateContactPreparation()
            PrivatePaykitService.setContactSharingCleanupPending(false)
            return PrivatePaykitError.privateUnavailable
        }

        XCTAssertNotNil(error)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: PrivatePaykitService.cleanupPendingKey))
    }

    @MainActor
    func testDisablingSharingStopsPreparationStartedDuringWithdrawal() async throws {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: PublicPaykitService.publishingEnabledKey)
        defaults.set(true, forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(false, forKey: ContactPaymentsService.confirmedPreferenceKey)
        PublicPaykitService.setCleanupPending(false)
        PrivatePaykitService.setContactSharingCleanupPending(false)
        defaults.removeObject(forKey: PrivatePaykitService.cacheStateKey)
        defaults.removeObject(forKey: PrivatePaykitService.deletedContactCleanupKeysKey)

        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let endpoint = PublicPaykitService.Endpoint(
            methodId: .regtestOnchainP2wpkh, value: "bcrt1qendpoint", min: nil, max: nil,
            rawPayload: #"{"value":"bcrt1qendpoint"}"#
        )
        var publications = 0
        let service = PrivatePaykitService(publicationOperations: .init(
            currentPublicKey: { "pubkylocal" },
            ensureLink: { _ in .linked },
            buildEndpoints: { _ in [endpoint] },
            syncPaymentLists: { _ in
                publications += 1
                return .init(queued: [], cleared: [], failedToQueue: [], failedToDeliver: [])
            }
        ))
        var contactState = PrivatePaykitService.ContactState()
        contactState.hasPublishedPrivatePaymentList = true
        await service.setTestContactState(contactState, publicKey: publicKey)

        let withdrawing = expectation(description: "Private withdrawal started")
        let prepared = expectation(description: "Preparation completes while withdrawal is suspended")
        let (resume, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        var registryUpdates = 0
        let cleanup = PrivatePaykitService.EndpointCleanupOperations(
            linkedPeers: { [] },
            clearPaymentLists: { keys in
                XCTAssertEqual(keys, [publicKey])
                withdrawing.fulfill()
                for await _ in resume {
                    break
                }
                return .init(
                    queued: [], cleared: [.init(counterparty: publicKey, outboundMessageId: 1, error: nil)],
                    failedToQueue: [], failedToDeliver: []
                )
            },
            drainMessages: { XCTAssertEqual($0, [publicKey]) },
            pendingDrainKeys: { _ in [] },
            syncApp: {
                XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
                XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
                registryUpdates += 1
            }
        )
        let disable = Task {
            try await ContactPaymentsService.setEnabled(
                false, contactPublicKeys: [publicKey], canUsePrivatePayments: true,
                operations: .init(
                    syncPublicEndpoints: { publish, _ in
                        XCTAssertFalse(publish)
                        XCTAssertEqual(registryUpdates, 1)
                        XCTAssertTrue(PublicPaykitService.isCleanupPending)
                    },
                    preparePrivateEndpoints: { _, _, _ in XCTFail("OFF must not publish"); return nil },
                    removePrivateEndpoints: { _ in try await service.removePublishedEndpoints(operations: cleanup) },
                    setPublicCleanupPending: PublicPaykitService.setCleanupPending,
                    setPrivateCleanupPending: PrivatePaykitService.setContactSharingCleanupPending
                )
            )
        }
        await fulfillment(of: [withdrawing], timeout: 2)
        XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
        XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
        XCTAssertTrue(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey))
        XCTAssertTrue(PublicPaykitService.isCleanupPending)
        XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
        XCTAssertEqual(PrivatePaykitService.fullCleanupReconciliationMode(), .removePublishedState)

        let preparationError = await service.prepareSavedContacts([publicKey], wallet: WalletViewModel())
        XCTAssertNil(preparationError)
        let waiter = Task {
            try await service.awaitContactPreparation()
            prepared.fulfill()
        }
        await fulfillment(of: [prepared], timeout: 2)
        continuation.finish()
        try await disable.value
        try await waiter.value

        XCTAssertEqual(publications, 0)
        XCTAssertEqual(registryUpdates, 1)
        XCTAssertFalse(ContactPaymentsService.isEnabled())
        XCTAssertFalse(PublicPaykitService.isCleanupPending)
        XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
    }

    func testCleanupStopsAStalledPreparationBeforeLaterContactsAreVisited() async {
        let service = PrivatePaykitService()
        let publicKeys = [
            "pubky1rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg",
            "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg",
        ]
        _ = await service.rememberSavedContacts(publicKeys, replacing: true)
        let started = expectation(description: "Link lookup started")
        let cleanupFinished = expectation(description: "Cleanup finished")
        let (resume, continuation) = AsyncStream<Void>.makeStream()
        var visitedKeys = [String]()
        let publication = Task {
            await service.syncLocalEndpointPublication(
                for: publicKeys, reason: "test", requireImmediatePublication: true,
                operations: .init(
                    currentPublicKey: { "pubkylocal" },
                    ensureLink: { key in
                        visitedKeys.append(key)
                        started.fulfill()
                        for await _ in resume {
                            break
                        }
                        return .linked
                    },
                    buildEndpoints: { _ in XCTFail("Cleanup invalidates preparation"); return [] },
                    syncPaymentLists: { _ in
                        XCTFail("Cleanup invalidates publication")
                        return .init(queued: [], cleared: [], failedToQueue: [], failedToDeliver: [])
                    }
                )
            )
        }
        await fulfillment(of: [started], timeout: 2)
        let cleanup = Task {
            try await service.removePublishedEndpoints(operations: .init(
                linkedPeers: { [] },
                clearPaymentLists: { _ in nil },
                drainMessages: { _ in },
                pendingDrainKeys: { _ in [] },
                syncApp: {}
            ))
            cleanupFinished.fulfill()
        }
        await fulfillment(of: [cleanupFinished], timeout: 2)
        continuation.yield(())
        continuation.finish()
        let error = await publication.value
        _ = await cleanup.result

        XCTAssertEqual(visitedKeys, [publicKeys[0]])
        XCTAssertNotNil(error)
    }

    func testPublicationDropsContactsRemovedWhileLinking() async {
        let service = PrivatePaykitService()
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        _ = await service.rememberSavedContacts([publicKey], replacing: true)
        let error = await service.syncLocalEndpointPublication(
            for: [publicKey], reason: "test", requireImmediatePublication: true,
            operations: .init(
                currentPublicKey: { "pubkylocal" },
                ensureLink: { _ in
                    _ = await service.rememberSavedContacts([], replacing: true)
                    return .linked
                },
                buildEndpoints: { _ in XCTFail("Removed contacts must not reserve addresses"); return [] },
                syncPaymentLists: { _ in
                    XCTFail("Removed contacts must not receive publications")
                    return .init(queued: [], cleared: [], failedToQueue: [], failedToDeliver: [])
                }
            )
        )
        XCTAssertNil(error)
    }

    func testUnavailableContactCooldownDoesNotBlockExplicitPublication() async {
        let service = PrivatePaykitService()
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        _ = await service.rememberSavedContacts([publicKey], replacing: true)
        var attempts = 0
        let operations = PrivatePaykitService.EndpointPublicationOperations(
            currentPublicKey: { "pubkylocal" },
            ensureLink: { _ in
                attempts += 1
                throw PaykitError.NotFound(code: "not_found", context: "No App Registry")
            },
            buildEndpoints: { _ in XCTFail("Unavailable contacts must not reserve addresses"); return [] },
            syncPaymentLists: { _ in .init(queued: [], cleared: [], failedToQueue: [], failedToDeliver: []) }
        )
        for _ in 0 ..< 3 {
            _ = await service.syncLocalEndpointPublication(
                for: [publicKey], reason: "test", requireImmediatePublication: false, operations: operations
            )
        }
        XCTAssertEqual(attempts, 1)
        _ = await service.syncLocalEndpointPublication(
            for: [publicKey], reason: "test", requireImmediatePublication: true, operations: operations
        )
        XCTAssertEqual(attempts, 2)
    }

    func testTransportFailureOnlyDefersContactsWithoutAHandshakeAfterAdvancement() async {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let states: [LinkedPeerState?] = [nil, .notLinked, .linking, .recoveryRequired]
        for stateAfterFailure in states {
            let service = PrivatePaykitService()
            _ = await service.rememberSavedContacts([publicKey], replacing: true)
            var peerState: LinkedPeerState?
            var nextState: LinkedPeerState?
            var attempts = 0
            let peers: () async throws -> [LinkedPeerRecord] = {
                guard let peerState else { return [] }
                return [LinkedPeerRecord(
                    counterparty: publicKey, state: peerState,
                    lastSyncAt: nil, lastPrivateReceiveAt: nil, failureCount: 0,
                    localRecoveryAttemptId: nil, localRecoveryMarkerCreatedAt: nil, localRecoveryMarkerLastError: nil,
                    remoteRecoveryAttemptId: nil, remoteRecoveryMarkerObservedAt: nil
                )]
            }
            let operations = PrivatePaykitService.EndpointPublicationOperations(
                currentPublicKey: { "pubkylocal" },
                ensureLink: { _ in
                    attempts += 1
                    peerState = nextState
                    throw PaykitError.Transport(code: "offline", context: "Unavailable homeserver")
                },
                buildEndpoints: { _ in XCTFail("Failed links must not reserve addresses"); return [] },
                syncPaymentLists: { _ in .init(queued: [], cleared: [], failedToQueue: [], failedToDeliver: []) },
                linkedPeers: peers
            )
            _ = await service.syncLocalEndpointPublication(
                for: [publicKey], reason: "test", requireImmediatePublication: false, operations: operations
            )
            nextState = stateAfterFailure
            _ = await service.syncLocalEndpointPublication(
                for: [publicKey], reason: "test", requireImmediatePublication: true, operations: operations
            )
            await service.clearTestPendingMessageDrainRetries()
            await service.drainPendingPrivateMessages(reason: "test retry", advancing: [publicKey], operations: .init(
                ensureLink: { _ in attempts += 1 },
                pendingOutbound: { [] },
                linkedPeers: peers,
                processPending: { _ in XCTFail("No outbound messages are queued") },
                receive: { _ in XCTFail("The handshake has not completed") }
            ))

            XCTAssertEqual(attempts, stateAfterFailure == nil || stateAfterFailure == .notLinked ? 2 : 3)
        }
    }

    func testRemovedContactStateDoesNotRetainUnavailableLinkCooldown() async {
        PrivatePaykitService.setContactSharingCleanupPending(false)
        PrivatePaykitService.clearDeletedContactCleanupPending()
        UserDefaults.standard.removeObject(forKey: PrivatePaykitService.cacheStateKey)
        let service = PrivatePaykitService()
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        var attempts = 0
        let operations = PrivatePaykitService.EndpointPublicationOperations(
            currentPublicKey: { "pubkylocal" },
            ensureLink: { _ in
                attempts += 1
                throw PaykitError.NotFound(code: "not_found", context: "No App Registry")
            },
            buildEndpoints: { _ in XCTFail("Unavailable contacts must not reserve addresses"); return [] },
            syncPaymentLists: { _ in .init(queued: [], cleared: [], failedToQueue: [], failedToDeliver: []) }
        )
        let removals: [(PrivatePaykitService) async -> Void] = [
            { await $0.clearContactState(publicKey: publicKey) },
            { _ = await $0.rememberSavedContacts([], replacing: true) },
            { await $0.pruneUnsavedContactState(savedPublicKeys: []) },
        ]
        for (index, remove) in removals.enumerated() {
            _ = await service.rememberSavedContacts([publicKey], replacing: true)
            _ = await service.syncLocalEndpointPublication(
                for: [publicKey], reason: "test", requireImmediatePublication: false, operations: operations
            )
            XCTAssertEqual(attempts, index + 1)
            await remove(service)
        }
        _ = await service.rememberSavedContacts([publicKey], replacing: true)
        _ = await service.syncLocalEndpointPublication(
            for: [publicKey], reason: "test", requireImmediatePublication: false, operations: operations
        )
        XCTAssertEqual(attempts, removals.count + 1)
    }

    private func withIsolatedPrivatePaykitState(
        _ operation: (PrivatePaykitService) async throws -> Void
    ) async throws {
        let defaults = UserDefaults.standard
        let previousState = defaults.data(forKey: PrivatePaykitService.cacheStateKey)
        defaults.removeObject(forKey: PrivatePaykitService.cacheStateKey)
        defer {
            if let previousState {
                defaults.set(previousState, forKey: PrivatePaykitService.cacheStateKey)
            } else {
                defaults.removeObject(forKey: PrivatePaykitService.cacheStateKey)
            }
        }
        try await operation(PrivatePaykitService())
    }
}

private final class CleanupDeliveryError: PrivateOperationError, @unchecked Sendable {
    override func redactedContext() -> String {
        "Delivery failed"
    }
}

private extension PrivatePaykitService {
    func setTestRetry(_ retry: PrivateMessageRetry, for publicKey: String) {
        pendingMessageDrainRetries[publicKey] = retry
    }

    func setTestContactState(_ contactState: ContactState, publicKey: String) {
        state.contacts[publicKey] = contactState
    }

    func setTestLocalInvoice(_ invoice: StoredInvoice, publicKey: String) {
        state.contacts[publicKey] = ContactState()
        state.contacts[publicKey]?.localInvoice = invoice
    }

    func testContactState(publicKey: String) -> ContactState? {
        state.contacts[publicKey]
    }

    func testPendingMessageDrainRetryKeys() -> Set<String> {
        pendingMessageDrainRetryKeys
    }

    func clearTestPendingMessageDrainRetries() {
        invalidateContactPreparation()
    }
}
