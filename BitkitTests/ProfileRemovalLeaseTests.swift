@testable import Bitkit
import XCTest

@MainActor
final class ProfileRemovalLeaseTests: XCTestCase {
    private var directory: URL!
    private var store: ProfileRemovalStore!
    private var admission: ProfileOperationAdmission!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = ProfileRemovalStore(url: directory.appendingPathComponent("pending.json"))
        admission = ProfileOperationAdmission(store: store)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testRetiringIdleIntentAllowsExactLocalRecovery() async throws {
        let id = UUID()
        let scope = try admission.reserve(kind: .removal, id: id, expected: admission.snapshot())
        let remote = ProfileRevocationTestDouble()
        let handle = remote.handle()
        let lease = ProfileRemovalLease(scope: scope, revokeRemoteAdmission: handle.revoke)
        try await lease.withOperation { try self.admission.persist(scope) }
        XCTAssertTrue(lease.canResume)
        lease.retire()
        lease.retire()
        XCTAssertTrue(remote.revoked)
        XCTAssertFalse(lease.canResume)
        let local = try admission.reserve(kind: .localRecovery, id: id)
        defer { admission.release(local) }
        try await admission.drain(before: local)
        try admission.complete(local)
    }

    func testWipeRevokesIdleAuthorityButDrainsActiveTailUntilItActuallyReturns() async throws {
        let id = UUID()
        let scope = try admission.reserve(kind: .removal, id: id, expected: admission.snapshot())
        let remote = ProfileRevocationTestDouble()
        let handle = remote.handle()
        let lease = ProfileRemovalLease(scope: scope, revokeRemoteAdmission: handle.revoke)
        let active = expectation(description: "Original native work is active")
        let barrier = NativeTail()
        let operation = Task {
            try await lease.withOperation {
                try self.admission.persist(scope)
                await barrier.wait { active.fulfill() }
            }
        }
        await fulfillment(of: [active], timeout: 2)
        XCTAssertFalse(lease.canResume)
        let wipe = try admission.reserve(kind: .walletWipe, id: UUID())
        defer { admission.release(wipe) }
        XCTAssertTrue(remote.revoked)
        let waiting = expectation(description: "Wipe starts draining")
        var drained = false
        let wipeTask = Task {
            waiting.fulfill()
            try await admission.drain(before: wipe)
            drained = true
        }
        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertFalse(drained, "Releasing the idle holder must not release active native work")
        await barrier.finish()
        do { _ = try await operation.value; XCTFail("Wipe ended original admission") }
        catch ProfileRemovalStore.StoreError.changed {}
        try await wipeTask.value
        XCTAssertTrue(drained)
        XCTAssertFalse(lease.canResume)
    }

    func testCancellationRetiresIdleHolderAndCannotReviveIntent() async throws {
        let id = UUID()
        let scope = try admission.reserve(kind: .removal, id: id, expected: admission.snapshot())
        let remote = ProfileRevocationTestDouble()
        let handle = remote.handle()
        let lease = ProfileRemovalLease(scope: scope, revokeRemoteAdmission: handle.revoke)
        let active = expectation(description: "Native work entered")
        let barrier = NativeTail()
        let operation = Task {
            try await lease.withOperation {
                try self.admission.persist(scope)
                await barrier.wait { active.fulfill() }
            }
        }
        await fulfillment(of: [active], timeout: 2)
        operation.cancel()
        XCTAssertTrue(remote.revoked)
        XCTAssertFalse(lease.canResume)
        XCTAssertThrowsError(try admission.reserve(kind: .localRecovery, id: id), "Active holder still owns its tail")
        await barrier.finish()
        do { _ = try await operation.value; XCTFail("Cancelled operation cannot succeed") }
        catch is CancellationError {}
        let local = try admission.reserve(kind: .localRecovery, id: id)
        defer { admission.release(local) }
        try await admission.drain(before: local)
        XCTAssertFalse(lease.canResume)
    }

    private actor NativeTail {
        private var continuation: CheckedContinuation<Void, Never>?
        func wait(entered: @Sendable () -> Void) async {
            await withCheckedContinuation { continuation = $0; entered() }
        }

        func finish() {
            continuation?.resume(); continuation = nil
        }
    }
}
