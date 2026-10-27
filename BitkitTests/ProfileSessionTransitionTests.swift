@testable import Bitkit
import XCTest

@MainActor
final class ProfileSessionTransitionTests: XCTestCase {
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

    func testFailedCreationHandsItsOwnNewRevisionBackForExplicitRetry() async throws {
        snapshotAppDefaultsDomain()
        let manager = PubkyProfileManager()
        let admission = ProfileOperationAdmission.shared
        var owner = manager.removalPresentationOwner
        var generation = try admission.snapshot()
        for _ in 0 ..< 2 {
            let handedBack = expectation(description: "Reconciled failure returns an exact retry context")
            try await admission.withSessionTransition(expected: generation) {
                XCTAssertTrue(manager.ownsRemovalPresentation(owner))
                do {
                    try await manager.createIdentity(name: "Original", bio: "", links: [], loadStoredSecretKey: {
                        throw URLError(.notConnectedToInternet)
                    })
                    XCTFail("The controlled remote preparation must fail")
                } catch let error as URLError {
                    XCTAssertEqual(error.code, .notConnectedToInternet)
                    XCTAssertFalse(manager.ownsRemovalPresentation(owner), "The manager advances its session revision even on failure")
                    try manager.schedulePresentationContext { nextOwner, nextGeneration in
                        owner = nextOwner; generation = nextGeneration
                        handedBack.fulfill()
                    }
                }
            }
            await fulfillment(of: [handedBack], timeout: 2)
            XCTAssertTrue(manager.ownsRemovalPresentation(owner))
            XCTAssertNoThrow(try admission.validate(generation))
        }
    }

    func testCreationDoesNotAuthenticateAgainAfterRequiredLocalSignupFailure() async throws {
        for error: Error in [Bitkit.KeychainError.failedToSave,
                             PubkyCredentialLocalError(
                                 underlyingError: Bitkit.KeychainError.failedToSave,
                                 cleanupError: Bitkit.KeychainError.failedToDelete
                             ),
                             ProfileRemovalStore.StoreError.unavailable]
        {
            var fallbacks = 0
            try await ProfileOperationAdmission.shared.withSessionTransition {
                do {
                    _ = try await PubkyProfileManager.signUpOrSignIn(signUp: { throw error }, signIn: {
                        fallbacks += 1
                        return "replacement"
                    })
                    XCTFail("Required local failure must escape the authentication fallback")
                } catch {
                    XCTAssertTrue(error is Bitkit.KeychainError || error is PubkyCredentialLocalError || error is ProfileRemovalStore.StoreError)
                }
            }
            XCTAssertEqual(fallbacks, 0)
        }
    }

    func testCreationRetainsRemoteRegistrationFallbackForItsOriginalOwner() async throws {
        var fallbacks = 0
        let result = try await ProfileOperationAdmission.shared.withSessionTransition {
            try await PubkyProfileManager.signUpOrSignIn(signUp: { throw PubkyServiceError.authFailed("Already registered") }, signIn: {
                fallbacks += 1
                return "original"
            })
        }
        XCTAssertEqual(result, "original")
        XCTAssertEqual(fallbacks, 1)
    }

    func testQueuedPresentationHandoffCannotCaptureASuccessorWipe() async throws {
        let manager = PubkyProfileManager(removalStore: store, removalAdmission: admission)
        let transition = try admission.reserveSessionTransition()
        var handedBack = false
        try await admission.withScope(transition, access: .control) {
            try manager.schedulePresentationContext { _, _ in handedBack = true }
        }
        admission.release(transition)
        let wipe = try admission.reserve(kind: .walletWipe, id: UUID())
        admission.revoke(wipe)
        admission.release(wipe)
        // The queued callback cannot run on MainActor until this function yields.
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        XCTAssertFalse(handedBack)
        XCTAssertNoThrow(try admission.snapshot())
    }

    func testTransitionDrainsEarlierOuterWorkBeforeMutation() async throws {
        let old = try admission.capture()
        let transition = try admission.reserveSessionTransition()
        var entered = false
        let operation = Task {
            try await admission.withScope(transition, access: .control) {
                try await admission.drain(before: transition)
                try admission.checkCurrent()
                entered = true
            }
        }
        await Task.yield()
        XCTAssertFalse(entered)
        XCTAssertThrowsError(try admission.validate(old))
        XCTAssertThrowsError(try admission.capture())
        admission.release(old)
        try await operation.value
        XCTAssertTrue(entered)
        admission.release(transition)
        XCTAssertNoThrow(try admission.snapshot())
        XCTAssertNil(try store.pending())
    }

    func testNestedTransitionReusesOwnerButStableSnapshotsRemainClosed() async throws {
        let before = try admission.snapshot()
        try await admission.withSessionTransition {
            XCTAssertThrowsError(try self.admission.snapshot())
            let operation = try self.admission.operationGeneration()
            XCTAssertEqual(operation, before)
            try await self.admission.withSessionTransition(expected: operation) {
                try self.admission.validateOperationGeneration(operation)
                try await self.admission.withOperation { try self.admission.checkCurrent() }
            }
            let gate = try XCTUnwrap(self.admission)
            let competing = Task.detached { try gate.reserveSessionTransition() }
            do { _ = try await competing.value; XCTFail("An unrelated transition entered") }
            catch ProfileRemovalStore.StoreError.changed {}
        }
        XCTAssertThrowsError(try admission.validate(before))
        XCTAssertNil(try store.pending())
    }

    func testOrdinaryScopeCannotUpgradeItsInheritedChildren() async throws {
        try await admission.withOperation {
            do {
                try await self.admission.withSessionTransition { XCTFail("Ordinary scope was upgraded") }
                XCTFail("A new transition must start at its outer entry")
            } catch ProfileRemovalStore.StoreError.changed {}
            try self.admission.checkCurrent()
        }
    }

    func testRegistrationGenerationCanActivateOnce() async throws {
        let registration = try admission.snapshot()
        try await admission.withSessionTransition(expected: registration) {
            try self.admission.validateOperationGeneration(registration)
        }
        do {
            try await admission.withSessionTransition(expected: registration) { XCTFail("Old registration was reused") }
            XCTFail("Ended registration must be stale")
        } catch ProfileRemovalStore.StoreError.changed {}
    }

    func testPendingAndUnavailableStorageCannotStartTransition() throws {
        try store.begin(id: UUID())
        XCTAssertThrowsError(try admission.reserveSessionTransition())
        try Data("unreadable-format".utf8).write(to: directory.appendingPathComponent("pending.json"))
        XCTAssertThrowsError(try admission.reserveSessionTransition())
    }

    func testTransitionCannotAcquireRemovalCompletionAuthority() async throws {
        try await admission.withSessionTransition {
            let scope = try XCTUnwrap(ProfileOperationAdmission.current)
            XCTAssertThrowsError(try self.admission.persist(scope))
            XCTAssertThrowsError(try self.admission.complete(scope))
            XCTAssertNil(try self.store.pending())
        }
    }

    func testOldTransitionReleaseCannotReopenPreemptingWipe() async throws {
        let transition = try admission.reserveSessionTransition()
        let wipe = try admission.reserve(kind: .walletWipe, id: UUID())
        admission.release(transition)
        XCTAssertTrue(admission.isWalletWiping)
        XCTAssertThrowsError(try admission.snapshot())
        try await admission.withScope(wipe, access: .control) { try await self.admission.drain(before: wipe) }
        admission.release(wipe)
        XCTAssertNoThrow(try admission.snapshot())
    }

    func testOptionalWorkReceivesCommittedOwnerWithoutRetainingTransition() async throws {
        let started = expectation(description: "Optional work scheduled after transition")
        let gate = try XCTUnwrap(admission)
        let old = try admission.snapshot()
        var scope: ProfileOperationAdmission.Scope?
        try await admission.withSessionTransition {
            try self.admission.scheduleAfterTransition { next in
                XCTAssertNil(ProfileOperationAdmission.current)
                started.fulfill()
                gate.release(next)
            }
            XCTAssertThrowsError(try self.admission.snapshot())
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertThrowsError(try admission.validate(old))
        try await admission.withSessionTransition { scope = ProfileOperationAdmission.current }
        XCTAssertNotNil(scope)
    }

    func testReplacementRejectsQueuedOptionalWorkFromEarlierTransition() async throws {
        let gate = try XCTUnwrap(admission)
        let holder = TransitionScopeHolder()
        try await gate.withSessionTransition {
            try gate.scheduleAfterTransition { holder.set($0) }
        }
        let optional = try XCTUnwrap(holder.get())
        let replacement = try gate.reserveSessionTransition()
        XCTAssertThrowsError(try gate.validate(optional))
        gate.release(optional)
        try await gate.withScope(replacement, access: .control) { try await gate.drain(before: replacement) }
        gate.release(replacement)
    }

    func testFailedRecoveryRecordBlocksNewIdentityAndKeepsWipeLocal() async throws {
        var allowWrite = false
        let failedStore = ProfileRemovalStore(url: directory.appendingPathComponent("failure.json"), write: { data, url in
            guard allowWrite else { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        })
        let gate = ProfileOperationAdmission(store: failedStore)
        do {
            try await gate.withSessionTransition {
                let receipt = try gate.retainLocalCompletion()
                defer { gate.release(receipt) }
                do { try gate.recordLocalCompletionFailure(receipt, id: UUID()); XCTFail("Marker write unexpectedly succeeded") }
                catch let error as CocoaError { XCTAssertEqual(error.code, .fileWriteNoPermission) }
                XCTAssertThrowsError(try gate.checkCurrent())
            }
            XCTFail("Unpersisted cleanup reopened the original transition")
        } catch ProfileRemovalStore.StoreError.changed {}
        XCTAssertTrue(gate.hasUnpersistedLocalFailure)
        XCTAssertNil(try failedStore.pending())
        XCTAssertThrowsError(try gate.snapshot())
        let unexpected = try? gate.reserveSessionTransition()
        if let unexpected {
            gate.release(unexpected)
        }
        XCTAssertNil(unexpected, "New identity must not bypass failed durable cleanup")
        allowWrite = true
        let wipe = try gate.reserve(kind: .walletWipe, id: UUID())
        defer { gate.release(wipe) }
        try await gate.withScope(wipe, access: .control) {
            try await gate.drain(before: wipe)
            try gate.persist(wipe)
            XCTAssertFalse(try gate.permitsRemoteCleanup(wipe), "Uncertain retained credentials must not authorize remote cleanup")
            try gate.complete(wipe)
        }
        XCTAssertFalse(gate.hasUnpersistedLocalFailure)
    }

    func testAcknowledgedCreationIsNotRolledBackByLateOriginalCancellation() async throws {
        let gate = try XCTUnwrap(admission)
        let committed = expectation(description: "Identity creation acknowledged")
        let (stream, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let task = Task {
            try await gate.withSessionTransition {
                try gate.acknowledgeSessionTransition(XCTUnwrap(ProfileOperationAdmission.current))
                committed.fulfill()
                for await _ in stream {}
                try gate.validateAcknowledgedCompletion()
                return 42
            }
        }
        await fulfillment(of: [committed], timeout: 1)
        task.cancel()
        release.finish()
        let result = try await task.value
        XCTAssertEqual(result, 42)
        XCTAssertNoThrow(try gate.snapshot())
    }

    func testAcknowledgedCreationStillRejectsWipeSupersession() async throws {
        let gate = try XCTUnwrap(admission)
        let scope = try gate.reserveSessionTransition()
        try ProfileOperationAdmission.$current.withValue(scope) { try gate.acknowledgeSessionTransition(scope) }
        let wipe = try gate.reserve(kind: .walletWipe, id: UUID())
        XCTAssertThrowsError(try ProfileOperationAdmission.$current.withValue(scope) { try gate.validateAcknowledgedCompletion() })
        gate.release(scope)
        try await gate.withScope(wipe, access: .control) { try await gate.drain(before: wipe) }
        gate.release(wipe)
    }

    func testFailedTransitionDropsOptionalWork() async throws {
        let gate = try XCTUnwrap(admission)
        do {
            try await gate.withSessionTransition {
                try gate.scheduleAfterTransition { _ in XCTFail("Failed transition scheduled a publication") }
                throw ProfileRemovalStore.StoreError.unavailable
            }
            XCTFail("Expected the original failure")
        } catch ProfileRemovalStore.StoreError.unavailable {}
        XCTAssertNoThrow(try gate.snapshot())
    }

    func testRevokedTransitionNeverSchedulesOptionalWork() throws {
        let gate = try XCTUnwrap(admission)
        let scope = try gate.reserveSessionTransition()
        try ProfileOperationAdmission.$current.withValue(scope) {
            try gate.scheduleAfterTransition { _ in XCTFail("Revoked owner scheduled optional work") }
        }
        gate.revoke(scope)
        gate.release(scope)
        XCTAssertNoThrow(try gate.snapshot())
    }

    func testExplicitReplacementDrainsBackgroundInitialization() async throws {
        let gate = try XCTUnwrap(admission)
        let initial = try gate.reserveSessionTransition(backgroundInitialization: true)
        let replacement = try gate.reserveSessionTransition()
        XCTAssertThrowsError(try gate.validate(initial))
        var entered = false
        let task = Task {
            try await gate.withScope(replacement, access: .control) {
                try await gate.drain(before: replacement)
                entered = true
            }
        }
        await Task.yield()
        XCTAssertFalse(entered)
        gate.release(initial)
        try await task.value
        XCTAssertTrue(entered)
        gate.release(replacement)
    }
}

private final class TransitionScopeHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var scope: ProfileOperationAdmission.Scope?
    func set(_ value: ProfileOperationAdmission.Scope) {
        lock.withLock { scope = value }
    }

    func get() -> ProfileOperationAdmission.Scope? {
        lock.withLock { scope }
    }
}
