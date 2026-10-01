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
}
