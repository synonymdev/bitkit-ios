@testable import Bitkit
import XCTest

final class ProfileOperationAdmissionTests: XCTestCase {
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

    func testReservationRevokesEarlierWorkAndDrainsItsActualTail() async throws {
        let original = try admission.capture()
        let generation = try admission.snapshot()
        let removal = try admission.reserve(kind: .removal, id: UUID(), expected: generation)
        defer { admission.release(removal) }
        XCTAssertThrowsError(try admission.validate(original))
        XCTAssertThrowsError(try admission.capture())
        let started = expectation(description: "Drain started")
        let completed = expectation(description: "Drain completed")
        let gate = try XCTUnwrap(admission)
        let drain = Task {
            started.fulfill()
            try await gate.drain(before: removal)
            completed.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertNil(try store.pending())
        admission.release(original)
        try await drain.value
        await fulfillment(of: [completed], timeout: 2)
        try admission.persist(removal)
        XCTAssertNotNil(try store.pending())
    }

    func testCancelledPreferenceCannotOverwriteAfterASuccessorReservationEvenIfCancelled() throws {
        let original = try admission.capture()
        defer { admission.release(original) }
        admission.revoke(original)
        XCTAssertNoThrow(try admission.validateCancelledPreference(original))
        let wipe = try admission.reserve(kind: .walletWipe, id: UUID())
        var preference = "successor"
        func restoreOldPreferenceIfAdmitted() {
            guard (try? admission.validateCancelledPreference(original)) != nil else { return }
            preference = "old"
        }
        restoreOldPreferenceIfAdmitted()
        XCTAssertEqual(preference, "successor")
        admission.revoke(wipe)
        admission.release(wipe)
        restoreOldPreferenceIfAdmitted()
        XCTAssertEqual(preference, "successor")
    }

    func testFinishedOrRevokedScopeCannotBecomeCurrentAgain() async throws {
        let original = try admission.capture()
        admission.release(original)
        do {
            try await admission.withScope(original) { XCTFail("Finished scope ran") }
            XCTFail("Finished scope accepted")
        } catch ProfileRemovalStore.StoreError.changed {}
        let expected = try admission.snapshot()
        let removal = try admission.reserve(kind: .removal, id: UUID(), expected: expected)
        try admission.persist(removal)
        try admission.complete(removal)
        admission.release(removal)
        XCTAssertThrowsError(try admission.validate(expected))
        XCTAssertThrowsError(try admission.reserve(kind: .removal, id: UUID(), expected: expected))
        XCTAssertNoThrow(try admission.snapshot())
    }

    func testPendingRestartAllowsOnlyExactLocalRecovery() async throws {
        let id = UUID()
        try store.begin(id: id)
        let restarted = ProfileOperationAdmission(store: ProfileRemovalStore(url: directory.appendingPathComponent("pending.json")))
        XCTAssertThrowsError(try restarted.capture())
        XCTAssertThrowsError(try restarted.reserve(kind: .localRecovery, id: UUID()))
        let recovery = try restarted.reserve(kind: .localRecovery, id: id)
        defer { restarted.release(recovery) }
        try await restarted.withScope(recovery, access: .control) {
            XCTAssertThrowsError(try restarted.capture())
            let local = try restarted.capture(access: .local)
            restarted.release(local)
            try restarted.complete(recovery)
        }
        XCTAssertNil(try store.pending())
        XCTAssertThrowsError(try restarted.validate(recovery))
    }

    func testWipePreemptsRemovalDrainWithoutOldReleaseReopeningAdmission() async throws {
        let original = try admission.capture()
        let removal = try admission.reserve(kind: .removal, id: UUID(), expected: admission.snapshot())
        let started = expectation(description: "Removal awaiting earlier work")
        let gate = try XCTUnwrap(admission)
        let older = Task {
            defer { gate.release(removal) }
            started.fulfill()
            do {
                try await gate.drain(before: removal)
                XCTFail("Revoked removal must not continue")
            } catch ProfileRemovalStore.StoreError.changed {}
        }
        await fulfillment(of: [started], timeout: 2)
        let wipe = try admission.reserve(kind: .walletWipe, id: UUID())
        defer { admission.release(wipe) }
        try await older.value
        XCTAssertThrowsError(try admission.capture())
        XCTAssertThrowsError(try admission.reserve(kind: .walletWipe, id: UUID()))
        admission.release(original)
        try await admission.drain(before: wipe)
        XCTAssertTrue(admission.isWalletWipe(wipe))
    }

    func testDetachedWorkerCancellationStillDrainsItsIgnoredCancellationTail() async throws {
        let gate = try XCTUnwrap(admission)
        let started = expectation(description: "Detached native work entered")
        let cancelled = expectation(description: "Worker cancellation requested")
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let original = Task {
            try await gate.withDetached {
                await withTaskCancellationHandler {
                    started.fulfill()
                    // A non-cancellable continuation models a native callback that has already entered.
                    await withCheckedContinuation { (held: CheckedContinuation<Void, Never>) in
                        Task.detached {
                            for await _ in stream {}
                            held.resume()
                        }
                    }
                } onCancel: { cancelled.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let removal = try admission.reserve(kind: .removal, id: UUID(), expected: admission.snapshot())
        defer { admission.release(removal) }
        await fulfillment(of: [cancelled], timeout: 2)
        continuation.finish()
        do {
            try await original.value
            XCTFail("Revoked worker returned success")
        } catch ProfileRemovalStore.StoreError.changed {
        } catch is CancellationError {}
        try await admission.drain(before: removal)
        try admission.persist(removal)
    }

    func testFailedMarkerWriteCannotAuthorizeCompletionOrLoseOriginalObligation() throws {
        let failing = ProfileRemovalStore(url: directory.appendingPathComponent("pending.json"), write: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        let gate = ProfileOperationAdmission(store: failing)
        let scope = try gate.reserve(kind: .removal, id: UUID(), expected: gate.snapshot())
        defer { gate.release(scope) }
        XCTAssertThrowsError(try gate.persist(scope))
        XCTAssertThrowsError(try gate.complete(scope))
        XCTAssertNil(try failing.pending())
    }

    func testRemoteCleanupRequiresAnAcknowledgedPendingRecord() throws {
        let scope = try admission.reserve(kind: .removal, id: UUID(), expected: admission.snapshot())
        defer { admission.release(scope) }
        XCTAssertThrowsError(try admission.validate(scope))
        XCTAssertNoThrow(try admission.validate(scope, access: .control))
        XCTAssertThrowsError(try admission.validate(scope, access: .local))
        try admission.persist(scope)
        XCTAssertNoThrow(try admission.validate(scope))
        try admission.complete(scope)
        XCTAssertThrowsError(try admission.validate(scope))
    }

    func testFailedPendingWriteLeavesRemotePermissionClosed() throws {
        let failing = ProfileRemovalStore(url: directory.appendingPathComponent("pending.json"), write: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        let gate = ProfileOperationAdmission(store: failing)
        let scope = try gate.reserve(kind: .removal, id: UUID(), expected: gate.snapshot())
        defer { gate.release(scope) }
        XCTAssertThrowsError(try gate.persist(scope))
        XCTAssertThrowsError(try gate.validate(scope))
    }

    func testSdkWipeReusesPendingAttemptAndOnlyForgetsLocalCredentials() async throws {
        let id = UUID()
        try store.begin(id: id)
        let provider = PaykitSdkSessionProvider(deleteKeychainValue: { _ in })
        let service = PaykitSdkService(sessionProvider: provider, profileAdmission: admission, sdkFactory: {
            XCTFail("Local recovery constructed SDK")
            throw CocoaError(.fileReadNoPermission)
        })
        try await service.withWalletWipe {
            try await service.forgetSessionAccess()
        }
        XCTAssertEqual(try store.pending()?.id, id, "The native barrier alone cannot acknowledge app cleanup")
    }

    func testWipePersistsAfterAnAlreadyAdmittedPriorCompletionRemovesTheMarker() async throws {
        let id = UUID()
        let removal = try admission.reserve(kind: .removal, id: id, expected: admission.snapshot())
        try admission.persist(removal)
        let wipe = try admission.reserve(kind: .walletWipe, id: UUID())
        defer { admission.release(wipe) }
        // The prior completion had entered its acknowledged store operation before the new reservation.
        try store.complete(id: id)
        admission.release(removal)
        try await admission.drain(before: wipe)
        try admission.persist(wipe)
        XCTAssertEqual(try store.pending()?.id, id)
        XCTAssertEqual(try store.pending()?.scope, .walletWipe)
        XCTAssertThrowsError(try admission.validate(wipe), "Recovery must stay local only")
    }

    func testPublicProviderNeverLoadsOrClearsRetainedCredentials() throws {
        let provider = PaykitSdkSessionProvider(publicOnly: true, loadSessionSecret: {
            XCTFail("Public provider loaded retained session")
            throw CocoaError(.fileReadNoPermission)
        }, deleteKeychainValue: { _ in XCTFail("Public provider deleted a credential") })
        XCTAssertNil(try provider.loadSessionAccess())
        XCTAssertNil(try provider.loadLocalSecretKey())
        XCTAssertTrue(try provider.publicStorageAvailable())
        XCTAssertThrowsError(try provider.clearSessionAccess())
    }

    func testStoreBeginRejectsAnEntireRemovalIntervalEvenWhenFileIsAbsentAgain() throws {
        let oldGeneration = try store.requireNoPending()
        let id = UUID()
        try store.begin(id: id)
        try store.complete(id: id)
        XCTAssertThrowsError(try store.begin(id: UUID(), expectedGeneration: oldGeneration))
        XCTAssertNil(try store.pending())
    }
}
