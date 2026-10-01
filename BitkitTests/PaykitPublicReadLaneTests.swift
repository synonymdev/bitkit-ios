@testable import Bitkit
import Paykit
import XCTest

final class PaykitPublicReadLaneTests: XCTestCase {
    /// Five bulk reads of each kind start, each blocked on its first network read. Only four may run, and a contact record
    /// read under the SDK lock and an interactive fetch must both finish meanwhile.
    func testBulkReadsLeaveTheSdkLockAndReadSlotsFree() async throws {
        let cases: [(name: String, read: @Sendable (PaykitSdkService, String) async throws -> Void)] = [
            ("profile lookup", { service, publicKey in
                let resolution = try await service.resolveContactProfile(publicKey: publicKey, allowPubkyProfileFallback: true, priority: .bulk)
                XCTAssertNil(resolution, "profile lookup")
            }),
            ("receiver discovery", { service, publicKey in
                let paths = try await service.discoverRelevantReceiverPaths(publicKey: publicKey, priority: .bulk)
                XCTAssertEqual(paths, [PaykitReceiverPath.wallet, PaykitReceiverPath.server], "receiver discovery")
            }),
            ("payment request receiver paths", { service, publicKey in
                let paths = try await service.paymentRequestReceiverPaths(publicKey: publicKey, priority: .bulk)
                XCTAssertEqual(paths, [PaykitReceiverPath.server], "payment request receiver paths")
            }),
            ("private receiver path selection", { service, publicKey in
                let selection = try await service.privateReceiverPathSelection(publicKey: publicKey, savedReceiverPaths: [PaykitReceiverPath.server])
                XCTAssertEqual(selection.linkableReceiverPaths, [PaykitReceiverPath.server], "private receiver path selection")
                XCTAssertEqual(selection.publishableReceiverPaths, [PaykitReceiverPath.server], "private receiver path selection")
                XCTAssertEqual(selection.cleanupProtectedReceiverPaths, [], "private receiver path selection")
                XCTAssertNil(selection.error, "private receiver path selection")
            }),
        ]
        for testCase in cases {
            let sdk = PublicReadLaneSdk(noPointer: .init())
            let service = PaykitSdkService(sdkFactory: { sdk })
            let reads = (0 ..< 5).map { index in
                Task { try await testCase.read(service, "contact\(index)") }
            }
            try await sdk.log.waitForEntries(count: 4)
            try await Task.sleep(for: .milliseconds(50))
            let readsInFlight = await sdk.log.entries.count
            XCTAssertEqual(readsInFlight, 4, "\(testCase.name): only four bulk reads may run at once")

            let lockedReadFinished = expectation(description: "\(testCase.name): contact record read under the SDK lock finished")
            let lockedRead = Task {
                _ = try await service.contactRecords()
                lockedReadFinished.fulfill()
            }
            let fetched = expectation(description: "\(testCase.name): interactive fetch finished")
            let fetch = Task {
                _ = try await service.fetchFile(uri: "pubky://avatar", maxBytes: 10)
                fetched.fulfill()
            }
            await fulfillment(of: [lockedReadFinished, fetched], timeout: 2)

            await sdk.gate.open()
            try await lockedRead.value
            try await fetch.value
            for read in reads {
                try await read.value
            }
        }
    }

    func testPrivateReceiverPathSelectionWithoutAnSdkProtectsEverySavedPath() async throws {
        let service = PaykitSdkService(sdkFactory: { throw PubkyServiceError.sessionNotActive })

        let selection = try await service.privateReceiverPathSelection(
            publicKey: "contact",
            savedReceiverPaths: [PaykitReceiverPath.server]
        )

        XCTAssertEqual(selection.linkableReceiverPaths, [])
        XCTAssertEqual(selection.publishableReceiverPaths, [])
        XCTAssertEqual(selection.cleanupProtectedReceiverPaths, [PaykitReceiverPath.wallet, PaykitReceiverPath.server])
        guard case .sessionNotActive? = selection.error as? PubkyServiceError else {
            return XCTFail("Expected sessionNotActive, got \(String(describing: selection.error))")
        }
    }

    func testPublicReadWaitingToBuildAnSdkWhenAWipeStartsFailsWithoutBuildingOne() async throws {
        let sdk = WipeRaceSdk(noPointer: .init())
        await sdk.gate.open()
        let builds = BuildCount()
        let bootstrap = HeldApprovalBootstrap(noPointer: .init())
        let service = PaykitSdkService(sdkFactory: {
            builds.increment()
            return sdk
        }) { _, _ in bootstrap }
        let approval = Task {
            try await service.approveAuth(
                authUrl: wipeRaceAuthURL, expectedCapabilities: "/pub/example/:rw", approvedClientID: "paykit.test",
                secretKeyHex: String(repeating: "01", count: 32)
            )
        }
        try await bootstrap.started.waitForEntries(count: 1)
        let read = Task { try await service.fetchPubkyFollows(publicKey: "follower") }
        try await Task.sleep(for: .milliseconds(50))
        let wipe = Task { try await service.withWalletWipe { builds.value } }
        try await Task.sleep(for: .milliseconds(50))

        await bootstrap.gate.open()
        try await approval.value
        await assertWipeError(read.result, "A read queued to build an SDK must not build or read once a wipe starts")
        let buildsByWipe = try await wipe.value
        XCTAssertEqual(buildsByWipe, 0)
        XCTAssertEqual(builds.value, 0, "Only work under the lock may build an SDK, and none was admitted")
        let reads = await sdk.log.entries
        XCTAssertEqual(reads, [])
    }

    func testPublicReadsDuringAWipeAreRejectedExceptForTheWipeItself() async throws {
        let sdk = WipeRaceSdk(noPointer: .init())
        await sdk.gate.open()
        let builds = BuildCount()
        let service = PaykitSdkService(sdkFactory: {
            builds.increment()
            return sdk
        })
        _ = try await service.contactRecords()
        let (cleanupStarted, startCleanup) = AsyncStream<Void>.makeStream()
        let (wipeGate, releaseWipe) = AsyncStream<Void>.makeStream()
        let wipe = Task {
            try await service.withWalletWipe {
                _ = try await service.contactRecords()
                let follows = try await service.fetchPubkyFollows(publicKey: "follower")
                XCTAssertEqual(follows, ["follow"], "The wipe's own public reads must still run")
                startCleanup.yield()
                for await _ in wipeGate {
                    break
                }
            }
        }
        for await _ in cleanupStarted {
            break
        }

        do {
            _ = try await service.fetchPubkyFollows(publicKey: "follower")
            XCTFail("Expected a public read during a wipe to be rejected")
        } catch let PaykitError.Storage(code, _) {
            XCTAssertEqual(code, "wallet_wipe_in_progress")
        }
        do {
            _ = try await service.privateReceiverPathSelection(publicKey: "follower", savedReceiverPaths: [PaykitReceiverPath.server])
            XCTFail("Expected a receiver path selection during a wipe to be rejected")
        } catch let PaykitError.Storage(code, _) {
            XCTAssertEqual(code, "wallet_wipe_in_progress")
        }
        let reads = await sdk.log.entries
        XCTAssertEqual(reads, ["follows:follower"], "Only the wipe's own read may reach the wiped wallet's SDK")
        XCTAssertEqual(builds.value, 2)

        releaseWipe.yield()
        try await wipe.value
        let follows = try await service.fetchPubkyFollows(publicKey: "follower")
        XCTAssertEqual(follows, ["follow"])
        XCTAssertEqual(builds.value, 3, "A read after the wipe builds a fresh SDK from the cleared state")
    }

    func testPublicReadThatAWipeOvertakesFailsWithoutDelayingTheWipe() async throws {
        let sdk = WipeRaceSdk(noPointer: .init())
        let service = PaykitSdkService(sdkFactory: { sdk })
        _ = try await service.contactRecords()
        let read = Task { try await service.fetchPubkyFollows(publicKey: "follower") }
        try await sdk.log.waitForEntries(count: 1)

        try await service.withWalletWipe {}
        await sdk.gate.open()

        await assertWipeError(read.result, "A read that a wipe overtook must not return its result across the wipe")
    }

    private func assertWipeError(
        _ result: Result<[String], Error>,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        switch result {
        case .success:
            XCTFail(message, file: file, line: line)
        case let .failure(PaykitError.Storage(code, _)):
            XCTAssertEqual(code, "wallet_wipe_in_progress", message, file: file, line: line)
        case let .failure(error):
            XCTFail("\(message): got \(error)", file: file, line: line)
        }
    }
}

/// Records the reads that have started, in order.
private actor PublicReadLog {
    private(set) var entries: [String] = []

    func record(_ entry: String) {
        entries.append(entry)
    }

    func waitForEntries(count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while entries.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Holds every read that waits on it until it opens. Unlike an `AsyncStream`, any number of reads can wait at once.
private actor PublicReadGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private final class PublicReadLaneSdk: PaykitSdk, @unchecked Sendable {
    let log = PublicReadLog()
    let gate = PublicReadGate()

    override func resolveContactProfile(
        publicKey: String,
        receiverPath _: String,
        allowPubkyProfileFallback _: Bool
    ) async throws -> ContactProfileResolution? {
        await log.record("profile:\(publicKey)")
        await gate.wait()
        return nil
    }

    override func fetchPubkyFileBounded(uri: String, maxBytes _: UInt64) async throws -> Data? {
        await log.record("file:\(uri)")
        return Data()
    }

    override func paykitReceiverPaths(publicKey: String) async throws -> [String] {
        await log.record("paths:\(publicKey)")
        await gate.wait()
        return [PaykitReceiverPath.wallet, PaykitReceiverPath.server]
    }

    /// The wallet path has no marker; the server path takes private payments and payment requests.
    override func paykitReceiverMarker(publicKey: String, receiverPath: String) async throws -> PaykitReceiverMarker? {
        await log.record("marker:\(publicKey):\(receiverPath)")
        await gate.wait()
        guard receiverPath == PaykitReceiverPath.server else { return nil }
        return PaykitReceiverMarker(
            receiverPath: receiverPath,
            capabilities: PaykitReceiverCapabilities(privatePayments: true, paymentRequests: true, receipts: false, outgoingPayments: true),
            noisePublicKey: "noise"
        )
    }

    override func contactRecords() async throws -> [ContactRecord] {
        []
    }
}

private let wipeRaceAuthURL =
    "pubkyauth://signin_grant?caps=/pub/example/:rw&relay=https://httprelay.pubky.app/inbox/" +
    "&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s" +
    "&cid=paykit.test&cpk=5jsjx1o6fzu6aeeo697r3i5rx15zq41kikcye8wtwdqm4nb4tryo"

/// Counts the SDKs a service builds. The factory runs on the service actor while the test reads the count.
private final class BuildCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

/// Holds an auth approval, which runs under the SDK lock without building an SDK, until its gate opens.
private final class HeldApprovalBootstrap: PubkySessionBootstrap, @unchecked Sendable {
    let started = PublicReadLog()
    let gate = PublicReadGate()

    override func approveAuth(authUrl _: String, expectedCapabilities _: String, localSecretKey _: PubkyLocalSecretKey) async throws {
        await started.record("approval")
        await gate.wait()
    }
}

/// Answers follow lookups once its gate opens and records each one that starts.
private final class WipeRaceSdk: PaykitSdk, @unchecked Sendable {
    let log = PublicReadLog()
    let gate = PublicReadGate()

    override func fetchPubkyFollows(publicKey: String) async throws -> [String] {
        await log.record("follows:\(publicKey)")
        await gate.wait()
        return ["follow"]
    }

    override func paykitReceiverMarker(publicKey: String, receiverPath: String) async throws -> PaykitReceiverMarker? {
        await log.record("marker:\(publicKey):\(receiverPath)")
        return nil
    }

    override func contactRecords() async throws -> [ContactRecord] {
        []
    }
}
