@testable import Bitkit
import Paykit
import XCTest

final class PaykitPublicReadLaneTests: XCTestCase {
    func testBulkProfileLookupsLeaveReadSlotsForInteractiveFetches() async throws {
        let sdk = PublicReadLaneSdk(noPointer: .init())
        let service = PaykitSdkService(sdkFactory: { sdk })
        let lookups = (0 ..< 6).map { index in
            Task {
                try await service.resolveContactProfile(publicKey: "contact\(index)", allowPubkyProfileFallback: true, priority: .bulk)
            }
        }
        try await sdk.log.waitForEntries(count: 4)
        try await Task.sleep(for: .milliseconds(50))
        let lookupsInFlight = await sdk.log.entries.count
        XCTAssertEqual(lookupsInFlight, 4, "Bulk lookups may hold only four of the six read slots")

        let fetched = expectation(description: "Interactive fetch finished")
        let fetch = Task {
            _ = try await service.fetchFile(uri: "pubky://avatar", maxBytes: 10)
            fetched.fulfill()
        }
        await fulfillment(of: [fetched], timeout: 2)

        await sdk.gate.open()
        try await fetch.value
        for lookup in lookups {
            _ = try await lookup.value
        }
    }

    func testReceiverDiscoveryDoesNotHoldTheSdkLock() async throws {
        let sdk = PublicReadLaneSdk(noPointer: .init())
        let service = PaykitSdkService(sdkFactory: { sdk })
        let discoveries = (0 ..< 5).map { index in
            Task { try await service.discoverRelevantReceiverPaths(publicKey: "contact\(index)", priority: .bulk) }
        }

        try await assertBulkReadsLeaveTheLockAndReadSlotsFree(sdk: sdk, service: service)

        for discovery in discoveries {
            let paths = try await discovery.value
            XCTAssertEqual(paths, [PaykitReceiverPath.wallet, PaykitReceiverPath.server])
        }
    }

    func testPaymentRequestReceiverPathsDoesNotHoldTheSdkLock() async throws {
        let sdk = PublicReadLaneSdk(noPointer: .init())
        let service = PaykitSdkService(sdkFactory: { sdk })
        let checks = (0 ..< 5).map { index in
            Task { try await service.paymentRequestReceiverPaths(publicKey: "contact\(index)", priority: .bulk) }
        }

        try await assertBulkReadsLeaveTheLockAndReadSlotsFree(sdk: sdk, service: service)

        for check in checks {
            let paths = try await check.value
            XCTAssertEqual(paths, [PaykitReceiverPath.server])
        }
    }

    func testPrivateReceiverPathSelectionDoesNotHoldTheSdkLock() async throws {
        let sdk = PublicReadLaneSdk(noPointer: .init())
        let service = PaykitSdkService(sdkFactory: { sdk })
        let selections = (0 ..< 5).map { index in
            Task {
                try await service.privateReceiverPathSelection(
                    publicKey: "contact\(index)",
                    savedReceiverPaths: [PaykitReceiverPath.server]
                )
            }
        }

        try await assertBulkReadsLeaveTheLockAndReadSlotsFree(sdk: sdk, service: service)

        for selection in selections {
            let result = try await selection.value
            XCTAssertEqual(result.linkableReceiverPaths, [PaykitReceiverPath.server])
            XCTAssertEqual(result.publishableReceiverPaths, [PaykitReceiverPath.server])
            XCTAssertEqual(result.cleanupProtectedReceiverPaths, [])
            XCTAssertNil(result.error)
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

    /// Expects five bulk reads to have been started, each blocked on its first network read. Four may run, a contact
    /// record read under the SDK lock and an interactive fetch must both finish meanwhile, then the gate opens.
    private func assertBulkReadsLeaveTheLockAndReadSlotsFree(
        sdk: PublicReadLaneSdk,
        service: PaykitSdkService,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await sdk.log.waitForEntries(count: 4)
        try await Task.sleep(for: .milliseconds(50))
        let readsInFlight = await sdk.log.entries.count
        XCTAssertEqual(readsInFlight, 4, "Only four bulk reads may run at once", file: file, line: line)

        let lockedReadFinished = expectation(description: "Contact record read under the SDK lock finished")
        let lockedRead = Task {
            _ = try await service.contactRecords()
            lockedReadFinished.fulfill()
        }
        let fetched = expectation(description: "Interactive fetch finished")
        let fetch = Task {
            _ = try await service.fetchFile(uri: "pubky://avatar", maxBytes: 10)
            fetched.fulfill()
        }
        await fulfillment(of: [lockedReadFinished, fetched], timeout: 2)

        await sdk.gate.open()
        try await lockedRead.value
        try await fetch.value
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
