@testable import Bitkit
import Paykit
import XCTest

@MainActor
final class ProfileRemovalCoordinatorTests: XCTestCase {
    private let owner = "pubky" + String(repeating: "y", count: 52)
    private var directory: URL!
    private var store: ProfileRemovalStore!
    private var admission: ProfileOperationAdmission!
    private var deleted: [(String, String)] = []
    private var steps: [String] = []
    private var nativeRevision = "confirmed-revision"
    private var profileAbsent = false
    private var failStep: String?
    private var cleanupCount = 0
    private var watermark = 42
    private var pauseID: UUID?
    private var resumeID: UUID?
    private var sourceMissing = false
    private var eligibilityChecks = 0
    private var duringEligibility: (() async throws -> Void)?
    private var duringRevocation: (() async throws -> Void)?
    private var duringPause: (() -> Void)?
    private var duringResume: (() async -> Void)?

    override func setUpWithError() throws {
        snapshotAppDefaultsDomain()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = ProfileRemovalStore(url: directory.appendingPathComponent("pending.json"))
        admission = ProfileOperationAdmission(store: store)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func makeManager(delete: (@Sendable (String, String) async throws -> Void)? = nil) -> PubkyProfileManager {
        let services = PubkyProfileManager.RemovalServices(
            readProfile: { [self] key in try await record(key: key) },
            deleteProfile: delete ?? { [self] key, revision in try await acknowledgeDelete(key: key, revision: revision) },
            withdrawPrivate: { [self] in try step("private") },
            withdrawPublic: { [self] in try step("public") },
            validateSubscriptions: { [self] expectedOwner in
                XCTAssertEqual(expectedOwner, owner)
                eligibilityChecks += 1
                try await duringEligibility?()
            },
            revokeSession: { [self] in try step("revoke"); try await duringRevocation?() },
            completeLocal: { [self] in
                try step("credentials")
                watermark = 0
                cleanupCount += 1
            },
            pause: { [self] in pauseID = $0; duringPause?() }, resume: { [self] in resumeID = $0; await duringResume?() }
        )
        let manager = PubkyProfileManager(removalServices: services, removalStore: store, removalAdmission: admission,
                                          sourceIsMissing: { [self] _, _ in sourceMissing })
        manager.publicKey = owner
        manager.authState = .authenticated
        return manager
    }

    private func record(key: String) throws -> PaykitProfileRecord? {
        if profileAbsent {
            return nil
        }
        return PaykitProfileRecord(publicKey: key, profile: PaykitProfile(displayName: "Owner", imageUri: nil, extraJson: nil),
                                   path: "/profile", revision: nativeRevision, updatedAt: "2026-10-27T00:00:00Z")
    }

    private func acknowledgeDelete(key: String, revision: String) throws {
        deleted.append((key, revision))
        try step("delete")
        guard revision == nativeRevision else { throw TestError.conflict }
    }

    private func step(_ name: String) throws {
        steps.append(name)
        if failStep == name {
            throw TestError.failure(name)
        }
    }

    private func contacts(failRemoval: Bool = false) -> ContactsManager {
        ContactsManager(contactRecords: { [] }, removeContactRecords: { _ in
            if failRemoval {
                throw TestError.failure("contacts")
            }
            return []
        }, profileAdmission: admission)
    }

    func testMissingAdoptedSourceSkipsSessionActivationAndUsesLocalCleanup() async throws {
        sourceMissing = true
        AdoptedPubkyReference.current = ("ring", owner)
        let manager = makeManager()
        await manager.initialize { XCTFail("A definitely removed source cannot activate retained credentials"); return .noSession }
        XCTAssertEqual(steps, ["credentials"])
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(watermark, 0)
        XCTAssertTrue(manager.adoptedSourceLost)
        XCTAssertTrue(manager.isInitialized)
        XCTAssertFalse(manager.isRestoringSession)
        XCTAssertNil(manager.publicKey)
        XCTAssertNil(try store.pending())
        XCTAssertNoThrow(try admission.snapshot())
    }

    func testMissingSourceCredentialFailureRetainsExactRecoveryForRestart() async throws {
        sourceMissing = true
        failStep = "credentials"
        AdoptedPubkyReference.current = ("ring", owner)
        let manager = makeManager()
        await manager.initialize { XCTFail("No SDK restoration is allowed"); return .noSession }
        let record = try XCTUnwrap(store.pending())
        XCTAssertEqual(record.scope, .profile)
        XCTAssertEqual(watermark, 42)
        XCTAssertFalse(manager.adoptedSourceLost)
        XCTAssertTrue(manager.isInitialized)
        XCTAssertFalse(manager.isRestoringSession)
        XCTAssertEqual(steps, ["credentials"])
        failStep = nil
        let restarted = makeManager()
        _ = try await restarted.finishPendingRemoval(id: record.id)
        XCTAssertEqual(steps, ["credentials", "credentials"])
        XCTAssertEqual(watermark, 0)
        XCTAssertNil(try store.pending())
        XCTAssertTrue(deleted.isEmpty)
    }

    func testReturningAdoptedSourceDuringPauseCancelsUnstartedCleanup() async throws {
        sourceMissing = true
        AdoptedPubkyReference.current = ("ring", owner)
        duringPause = { self.sourceMissing = false }
        let manager = makeManager()
        await manager.checkAdoptedSource()
        XCTAssertTrue(steps.isEmpty)
        XCTAssertNil(try store.pending())
        XCTAssertFalse(manager.adoptedSourceLost)
        XCTAssertEqual(manager.publicKey, owner)
        XCTAssertEqual(watermark, 42)
        XCTAssertThrowsError(try admission.snapshot(), "A known lost source remains quarantined until explicit local recovery")
        XCTAssertEqual(manager.removalRecovery, .unavailable)
    }

    func testSourceLossCompletionDoesNotNavigateAfterWipeTakesOwnership() async throws {
        sourceMissing = true
        AdoptedPubkyReference.current = ("ring", owner)
        let manager = makeManager()
        let resuming = expectation(description: "Local completion acknowledged")
        let (wait, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        duringResume = { resuming.fulfill(); for await _ in wait {} }
        let cleanup = Task { await manager.checkAdoptedSource() }
        await fulfillment(of: [resuming], timeout: 2)
        XCTAssertNil(try store.pending())
        let wipe = try admission.reserve(kind: .walletWipe, id: UUID())
        defer { admission.release(wipe) }
        release.finish()
        await cleanup.value
        XCTAssertFalse(manager.adoptedSourceLost, "The ended owner cannot navigate a replacement wipe")
    }

    func testCancelledSuccessorWipeStillInvalidatesOldRemovalPresentation() async throws {
        sourceMissing = true
        AdoptedPubkyReference.current = ("ring", owner)
        let manager = makeManager()
        let resuming = expectation(description: "Local completion acknowledged")
        let (wait, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        duringResume = { resuming.fulfill(); for await _ in wait {} }
        let cleanup = Task { await manager.checkAdoptedSource() }
        await fulfillment(of: [resuming], timeout: 2)
        XCTAssertNil(try store.pending())
        let wipe = try admission.reserve(kind: .walletWipe, id: UUID())
        admission.revoke(wipe)
        admission.release(wipe)
        XCTAssertFalse(admission.isWalletWiping)
        release.finish()
        await cleanup.value
        XCTAssertFalse(manager.adoptedSourceLost, "A canceled successor cannot restore an older completion's navigation authority")
    }

    func testFailedSourceLossMarkerDoesNotReopenIdentityAdmission() async throws {
        var failWrite = true
        store = ProfileRemovalStore(url: directory.appendingPathComponent("failed-marker.json"), write: { data, url in
            if failWrite {
                throw TestError.failure("marker")
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        })
        admission = ProfileOperationAdmission(store: store)
        sourceMissing = true
        AdoptedPubkyReference.current = ("ring", owner)
        let manager = makeManager()
        await manager.initialize { XCTFail("No retained-session activation"); return .noSession }
        XCTAssertEqual(manager.removalRecovery, .unavailable)
        XCTAssertEqual(watermark, 42)
        XCTAssertTrue(steps.isEmpty)
        XCTAssertThrowsError(try admission.snapshot())
        XCTAssertThrowsError(try admission.reserveSessionTransition())
        let sdk = PaykitSdkService(profileAdmission: admission, sdkFactory: {
            XCTFail("Quarantine must reject before SDK construction")
            throw TestError.failure("SDK")
        })
        do { _ = try await sdk.currentPublicKey(); XCTFail("Identity read reactivated a missing source") }
        catch ProfileRemovalStore.StoreError.changed {}
        failWrite = false
        manager.retryLocalRecoveryRecord()
        let pending = try XCTUnwrap(store.pending())
        XCTAssertEqual(manager.pendingProfileRemovalID, pending.id)
        XCTAssertEqual(pauseID, pending.id)
        _ = try await manager.finishPendingRemoval(id: pending.id)
        XCTAssertEqual(steps, ["credentials"])
        XCTAssertNil(try store.pending())
        XCTAssertNoThrow(try admission.snapshot())
    }

    func testMalformedMarkerRetryPreservesQuarantinedAttempt() async throws {
        let url = directory.appendingPathComponent("failed-marker.json")
        var failWrite = true
        store = ProfileRemovalStore(url: url, write: { data, url in
            if failWrite {
                throw TestError.failure("marker")
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        })
        admission = ProfileOperationAdmission(store: store)
        sourceMissing = true
        AdoptedPubkyReference.current = ("ring", owner)
        let manager = makeManager()
        await manager.initialize { XCTFail("No session activation"); return .noSession }
        let originalID = try XCTUnwrap(pauseID)
        XCTAssertEqual(manager.removalRecovery, .unavailable)
        failWrite = false
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let future = Data(#"{"version":2,"scope":"profile","id":"damaged"}"#.utf8)
        try future.write(to: url)
        manager.retryLocalRecoveryRecord()
        XCTAssertEqual(try Data(contentsOf: url), future)
        XCTAssertEqual(manager.removalRecovery, .unavailable)
        try Data(#"{"version":1,"scope":"profile","id":"damaged"}"#.utf8).write(to: url)
        manager.retryLocalRecoveryRecord()
        XCTAssertEqual(try store.pending()?.id, originalID)
        XCTAssertTrue(steps.isEmpty)
        XCTAssertEqual(watermark, 42)
        _ = try await manager.finishPendingRemoval(id: originalID)
        XCTAssertEqual(steps, ["credentials"])
        XCTAssertNil(try store.pending())
        XCTAssertNoThrow(try admission.snapshot())
    }

    func testQueuedConfirmationCannotCaptureReplacementScreenOwner() async throws {
        let manager = makeManager()
        let originalOwner = manager.removalPresentationOwner
        manager.publicKey = "pubky" + String(repeating: "z", count: 52)
        do {
            _ = try await manager.prepareRemoval(action: .deleteProfile, contacts: contacts(), expectedOwner: originalOwner)
            XCTFail("Old screen must not confirm a replacement identity")
        } catch PubkyProfileManager.RemovalError.confirmationChanged {}
        XCTAssertTrue(steps.isEmpty)
        XCTAssertNil(try store.pending())
    }

    func testWalletStartupRemainsIndependentOfProfileOnlyRecovery() throws {
        XCTAssertFalse(PubkyProfileManager.RemovalRecovery.ready.blocksWalletStartup)
        let id = UUID()
        try store.begin(id: id, scope: .profile)
        XCTAssertFalse(try PubkyProfileManager.RemovalRecovery.pending(XCTUnwrap(store.pending())).blocksWalletStartup)
        try store.begin(id: id, scope: .walletWipe)
        XCTAssertTrue(try PubkyProfileManager.RemovalRecovery.pending(XCTUnwrap(store.pending())).blocksWalletStartup)
        XCTAssertTrue(PubkyProfileManager.RemovalRecovery.unavailable.blocksWalletStartup)
    }

    func testCancelledAdoptionProfileReadKeepsPreviousSessionAndReference() async throws {
        AdoptedPubkyReference.current = ("ring", "previous-reference")
        let manager = makeManager()
        let sdk = PaykitSdkService(profileAdmission: admission, sdkFactory: {
            XCTFail("Injected sign-in and local rollback do not construct native SDK")
            throw TestError.failure("SDK")
        })
        let started = expectation(description: "Adoption profile read started")
        let (wait, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let adoption = Task {
            try await manager.adoptRingIdentity(pubky: "new-reference", loadSecret: { _, _ in String(repeating: "02", count: 32) },
                                                signIn: { _ in }, fetchProfile: { _ in
                                                    started.fulfill()
                                                    for await _ in wait {}
                                                    return nil
                                                }, sdkService: sdk)
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(manager.publicKey, owner, "Manager identity is not installed before the original attempt commits")
        adoption.cancel()
        do { _ = try await adoption.value; XCTFail("Cancelled adoption committed") } catch is CancellationError {}
        XCTAssertEqual(manager.publicKey, owner)
        XCTAssertEqual(manager.authState, .authenticated)
        XCTAssertEqual(AdoptedPubkyReference.current?.pubky, "previous-reference")
        XCTAssertNil(try store.pending())
        XCTAssertNoThrow(try admission.snapshot())
    }

    func testConfirmationCapturesOwnerBeforeDialogAndCannotBeConsumedTwice() async throws {
        let manager = makeManager()
        let confirmation = try await manager.prepareRemoval(action: .deleteProfile, contacts: contacts())
        let result = try await manager.confirmRemoval(confirmation)
        XCTAssertTrue(result.remoteProfileDeleted)
        XCTAssertEqual(deleted.count, 1)
        XCTAssertEqual(deleted.first?.0, owner)
        XCTAssertEqual(deleted.first?.1, "confirmed-revision")
        XCTAssertEqual(steps, ["private", "public", "delete", "revoke", "credentials"])
        XCTAssertEqual(pauseID, confirmation.id)
        XCTAssertEqual(resumeID, confirmation.id)
        XCTAssertNil(try store.pending())
        XCTAssertNil(manager.publicKey)
        do { _ = try await manager.confirmRemoval(confirmation); XCTFail("A copied confirmation cannot be replayed") }
        catch PubkyProfileManager.RemovalError.confirmationRequired {}
        XCTAssertEqual(deleted.count, 1)
    }

    func testCancelInvalidatesIssuedConfirmation() async throws {
        let manager = makeManager()
        let confirmation = try await manager.prepareRemoval(action: .disconnect)
        manager.cancelRemovalConfirmation(confirmation)
        do { _ = try await manager.confirmRemoval(confirmation); XCTFail("Cancelled intent cannot be consumed") }
        catch PubkyProfileManager.RemovalError.confirmationRequired {}
        do { try await manager.deleteProfile(); XCTFail("No-argument entry cannot reuse a cancelled alert") }
        catch PubkyProfileManager.RemovalError.confirmationRequired {}
        XCTAssertTrue(steps.isEmpty)
    }

    func testPresentationOwnerRejectsReplacementAndWipe() throws {
        let manager = makeManager()
        let original = manager.removalPresentationOwner
        XCTAssertTrue(manager.ownsRemovalPresentation(original))
        manager.publicKey = "replacement"
        XCTAssertFalse(manager.ownsRemovalPresentation(original))
        manager.publicKey = owner
        let wipe = try admission.reserve(kind: .walletWipe, id: UUID())
        defer { admission.release(wipe) }
        XCTAssertFalse(manager.ownsRemovalPresentation(original))
    }

    func testNoArgumentDeletionCannotRecaptureCurrentIdentity() async throws {
        let manager = makeManager()
        do { try await manager.deleteProfile(); XCTFail("A fresh confirmation is required") }
        catch PubkyProfileManager.RemovalError.confirmationRequired {}
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertTrue(steps.isEmpty)
    }

    func testConfirmationRejectsReplacementIdentityBeforeCleanup() async throws {
        let manager = makeManager()
        let confirmation = try await manager.prepareRemoval(action: .deleteProfile, contacts: contacts())
        manager.publicKey = "pubky" + String(repeating: "o", count: 52)
        do { _ = try await manager.confirmRemoval(confirmation); XCTFail("Replacement owner must remain untouched") }
        catch PubkyProfileManager.RemovalError.confirmationChanged {}
        XCTAssertTrue(steps.isEmpty)
        XCTAssertNil(try store.pending())
    }

    func testConfirmationRejectsSameKeyWithNewSessionRevision() async throws {
        let manager = makeManager()
        let confirmation = try await manager.prepareRemoval(action: .deleteProfile, contacts: contacts())
        try await PubkyProfileManager.restoreSessionBackupState(
            nil,
            deleteKeychainValue: { _ in },
            removeOwnSharedRecords: {},
            forgetSessionAccess: {}
        )
        XCTAssertEqual(manager.publicKey, owner)
        do { _ = try await manager.confirmRemoval(confirmation); XCTFail("Same key does not preserve the original session") }
        catch PubkyProfileManager.RemovalError.confirmationChanged {}
        XCTAssertTrue(steps.isEmpty)
    }

    func testFrozenProfileRevisionIsPassedToNativeConflictCheck() async throws {
        let manager = makeManager()
        let confirmation = try await manager.prepareRemoval(action: .deleteProfile, contacts: contacts())
        nativeRevision = "later-edit"
        do { _ = try await manager.confirmRemoval(confirmation); XCTFail("A later edit must not be deleted") }
        catch TestError.conflict {}
        XCTAssertEqual(deleted.first?.1, "confirmed-revision")
        XCTAssertEqual(cleanupCount, 0)
        XCTAssertEqual(watermark, 42)
        XCTAssertEqual(try store.pending()?.id, confirmation.id)
        XCTAssertNil(manager.currentSession)
        XCTAssertEqual(manager.publicKey, owner)
    }

    func testOriginallyAbsentProfileDoesNotDeleteLaterRecord() async throws {
        profileAbsent = true
        let manager = makeManager()
        let confirmation = try await manager.prepareRemoval(action: .deleteProfile, contacts: contacts())
        profileAbsent = false
        let result = try await manager.confirmRemoval(confirmation)
        XCTAssertFalse(result.remoteProfileDeleted)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testIncompletePrivateCleanupStopsContactsProfileAndLocalCleanup() async throws {
        failStep = "private"
        let manager = makeManager()
        let confirmation = try await manager.prepareRemoval(action: .deleteProfile, contacts: contacts())
        do { _ = try await manager.confirmRemoval(confirmation); XCTFail("Cleanup failed") }
        catch TestError.failure("private") {}
        XCTAssertEqual(steps, ["private"])
        XCTAssertEqual(watermark, 42)
        XCTAssertEqual(try store.pending()?.id, confirmation.id)
        XCTAssertNil(manager.automaticPaykitSession)
        XCTAssertEqual(manager.publicKey, owner)
    }

    func testIncompleteContactCleanupStopsProfileDeletion() async throws {
        let manager = makeManager()
        let confirmation = try await manager.prepareRemoval(action: .deleteProfile, contacts: contacts(failRemoval: true))
        do { _ = try await manager.confirmRemoval(confirmation); XCTFail("Contact cleanup failed") }
        catch TestError.failure("contacts") {}
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertEqual(cleanupCount, 0)
        XCTAssertNotNil(try store.pending())
    }

    func testCredentialFailureRetainsWatermarksAndRecoveryDoesNotRepeatRemoteWork() async throws {
        failStep = "credentials"
        let manager = makeManager()
        let confirmation = try await manager.prepareRemoval(action: .deleteProfile, contacts: contacts())
        do { _ = try await manager.confirmRemoval(confirmation); XCTFail("Credential failure must remain pending") }
        catch TestError.failure("credentials") {}
        XCTAssertEqual(watermark, 42)
        XCTAssertEqual(deleted.count, 1)
        failStep = nil
        let before = steps
        _ = try await manager.finishPendingRemoval(id: confirmation.id)
        XCTAssertEqual(steps, before + ["credentials"])
        XCTAssertEqual(deleted.count, 1)
        XCTAssertEqual(watermark, 0)
        XCTAssertNil(try store.pending())
    }

    func testRestartWithoutCredentialsAllowsOnlyExactIDLocalCompletion() async throws {
        let id = UUID()
        try store.begin(id: id)
        let manager = makeManager()
        manager.publicKey = nil
        manager.authState = .idle
        do { _ = try await manager.finishPendingRemoval(id: UUID()); XCTFail("Wrong UUID cannot finish another obligation") }
        catch PubkyProfileManager.RemovalError.confirmationChanged {}
        _ = try await manager.finishPendingRemoval(id: id)
        XCTAssertEqual(steps, ["credentials"])
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertNil(try store.pending())
    }

    func testUnlinkDoesNotDeleteRingOwnedProfile() async throws {
        let manager = makeManager()
        let confirmation = try await manager.prepareRemoval(action: .unlink, contacts: contacts())
        _ = try await manager.confirmRemoval(confirmation)
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertEqual(steps, ["private", "public", "revoke", "credentials"])
    }

    func testKnownSubscriptionRefusesPreparationWithoutBeginningCleanup() async throws {
        duringEligibility = { throw PubkyServiceError.activeSubscription(endsAt: nil) }
        for action in [PubkyProfileManager.RemovalAction.deleteProfile, .unlink] {
            let manager = makeManager()
            do { _ = try await manager.prepareRemoval(action: action, contacts: contacts()); XCTFail("Active subscriptions prevent removal") }
            catch PubkyServiceError.activeSubscription {}
            XCTAssertTrue(steps.isEmpty)
            XCTAssertNil(pauseID)
            XCTAssertNil(try store.pending())
            XCTAssertNotNil(manager.currentSession)
            XCTAssertNoThrow(try admission.snapshot())
            XCTAssertEqual(watermark, 42)
        }
    }

    func testSubscriptionAddedDuringDialogRefusesConfirmationBeforePending() async throws {
        for action in [PubkyProfileManager.RemovalAction.deleteProfile, .unlink] {
            duringEligibility = nil
            eligibilityChecks = 0
            let manager = makeManager()
            let confirmation = try await manager.prepareRemoval(action: action, contacts: contacts())
            duringEligibility = { throw PubkyServiceError.activeSubscription(endsAt: nil) }
            do { _ = try await manager.confirmRemoval(confirmation); XCTFail("Confirmation must recheck subscription eligibility") }
            catch PubkyServiceError.activeSubscription {}
            XCTAssertEqual(eligibilityChecks, 2)
            XCTAssertTrue(steps.isEmpty)
            XCTAssertNil(pauseID)
            XCTAssertNil(try store.pending())
            XCTAssertNotNil(manager.currentSession)
            XCTAssertNoThrow(try admission.snapshot())
        }
    }

    func testCancelledConfirmationDuringEligibilityCannotReserveRemoval() async throws {
        let manager = makeManager()
        let confirmation = try await manager.prepareRemoval(action: .deleteProfile, contacts: contacts())
        duringEligibility = { manager.cancelRemovalConfirmation(confirmation) }
        do { _ = try await manager.confirmRemoval(confirmation); XCTFail("Cancelled dialog must not reserve removal") }
        catch PubkyProfileManager.RemovalError.confirmationChanged {}
        XCTAssertTrue(steps.isEmpty)
        XCTAssertNil(pauseID)
        XCTAssertNil(try store.pending())
        XCTAssertNoThrow(try admission.snapshot())
    }

    func testLateSubscriptionRetainsPendingWithoutWithdrawingEndpoints() async throws {
        let manager = makeManager()
        let confirmation = try await manager.prepareRemoval(action: .deleteProfile, contacts: contacts())
        duringEligibility = { [self] in
            if eligibilityChecks == 3 {
                throw PubkyServiceError.activeSubscription(endsAt: nil)
            }
        }
        do { _ = try await manager.confirmRemoval(confirmation); XCTFail("Later remote changes remain fail-closed") }
        catch PubkyServiceError.activeSubscription {}
        XCTAssertTrue(steps.isEmpty)
        XCTAssertEqual(try store.pending()?.id, confirmation.id)
        XCTAssertEqual(watermark, 42)
    }

    func testOrdinaryDisconnectRevokesGrantBeforeLocalCredentials() async throws {
        let manager = makeManager()
        let confirmation = try await manager.prepareRemoval(action: .disconnect)
        _ = try await manager.confirmRemoval(confirmation)
        XCTAssertEqual(steps, ["private", "public", "revoke", "credentials"])
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertNil(try store.pending())
        XCTAssertEqual(watermark, 0)
    }

    func testUncertainRevocationRetainsOriginalObligationAndLocalRecoveryNeverReplaysIt() async throws {
        failStep = "revoke"
        let manager = makeManager()
        let confirmation = try await manager.prepareRemoval(action: .disconnect)
        do { _ = try await manager.confirmRemoval(confirmation); XCTFail("Revocation was not acknowledged") }
        catch TestError.failure("revoke") {}
        XCTAssertEqual(steps, ["private", "public", "revoke"])
        XCTAssertEqual(watermark, 42)
        XCTAssertEqual(try store.pending()?.id, confirmation.id)
        XCTAssertEqual(manager.publicKey, owner)
        failStep = nil
        _ = try await manager.finishPendingRemoval(id: confirmation.id)
        XCTAssertEqual(steps, ["private", "public", "revoke", "credentials"])
        XCTAssertNil(try store.pending())
    }

    func testRevocationOwnerChangeCannotClearReplacementCredentials() async throws {
        let manager = makeManager()
        duringRevocation = { manager.publicKey = "replacement" }
        let confirmation = try await manager.prepareRemoval(action: .disconnect)
        do { _ = try await manager.confirmRemoval(confirmation); XCTFail("Original owner ended") }
        catch PubkyProfileManager.RemovalError.confirmationChanged {}
        XCTAssertEqual(steps, ["private", "public", "revoke"])
        XCTAssertEqual(cleanupCount, 0)
        XCTAssertEqual(watermark, 42)
        XCTAssertEqual(try store.pending()?.id, confirmation.id)
        XCTAssertEqual(manager.publicKey, "replacement")
    }

    func testCancelledRevocationCannotEnterLocalFinalization() async throws {
        let started = expectation(description: "Original grant revocation entered")
        let barrier = NativeCompletion()
        duringRevocation = { await barrier.wait { started.fulfill() } }
        let manager = makeManager()
        let confirmation = try await manager.prepareRemoval(action: .disconnect)
        let operation = Task { try await manager.confirmRemoval(confirmation) }
        await fulfillment(of: [started], timeout: 2)
        operation.cancel()
        XCTAssertEqual(cleanupCount, 0)
        await barrier.finish()
        do { _ = try await operation.value; XCTFail("Cancellation must retain recovery") }
        catch is CancellationError {}
        XCTAssertEqual(steps, ["private", "public", "revoke"])
        XCTAssertEqual(watermark, 42)
        XCTAssertEqual(try store.pending()?.id, confirmation.id)
    }

    func testReadOnlySignOutDoesNotRequireRemoteAccess() async throws {
        let manager = makeManager()
        manager.publicKey = nil
        manager.authState = .idle
        let confirmation = try await manager.prepareRemoval(action: .disconnect)
        _ = try await manager.confirmRemoval(confirmation)
        XCTAssertEqual(steps, ["credentials"])
    }

    func testUncertain404LikeErrorNeverBecomesSuccess() async throws {
        let failure = NSError(domain: "SessionEndpoint", code: 404, userInfo: [NSLocalizedDescriptionKey: "Missing session"])
        let manager = makeManager(delete: { _, _ in throw failure })
        let confirmation = try await manager.prepareRemoval(action: .deleteProfile, contacts: contacts())
        do { _ = try await manager.confirmRemoval(confirmation); XCTFail("Missing session is not acknowledged profile deletion") }
        catch { XCTAssertEqual((error as NSError).domain, failure.domain) }
        XCTAssertEqual(watermark, 42)
        XCTAssertEqual(manager.publicKey, owner)
        XCTAssertNotNil(try store.pending())
    }

    func testCancelledAdmittedNativeWriteDrainsBeforeReleasingOwnership() async throws {
        let started = expectation(description: "Native write entered")
        let barrier = NativeCompletion()
        let manager = makeManager(delete: { _, _ in await barrier.wait { started.fulfill() } })
        let confirmation = try await manager.prepareRemoval(action: .deleteProfile, contacts: contacts())
        let operation = Task { try await manager.confirmRemoval(confirmation) }
        await fulfillment(of: [started], timeout: 2)
        operation.cancel()
        XCTAssertTrue(manager.isDeletingProfile)
        XCTAssertNil(manager.currentSession)
        XCTAssertThrowsError(try admission.snapshot())
        await barrier.finish()
        do { _ = try await operation.value; XCTFail("Cancellation cannot enter local finalization") }
        catch is CancellationError {}
        XCTAssertEqual(cleanupCount, 0)
        XCTAssertFalse(manager.isDeletingProfile)
        XCTAssertEqual(try store.pending()?.id, confirmation.id)
    }

    private enum TestError: Error { case failure(String), conflict }
    private actor NativeCompletion {
        var continuation: CheckedContinuation<Void, Never>?
        func wait(started: @Sendable () -> Void) async {
            await withCheckedContinuation { continuation = $0; started() }
        }

        func finish() {
            continuation?.resume(); continuation = nil
        }
    }
}
