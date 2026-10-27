@testable import Bitkit
import XCTest

@MainActor
final class ProfileWipeAdmissionTests: XCTestCase {
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

    private func service(delete: @escaping (Bitkit.KeychainEntryType) throws -> Void = { _ in }) -> PaykitSdkService {
        PaykitSdkService(sessionProvider: .init(loadSessionSecret: {
            XCTFail("Local wipe must not load a retained session")
            return nil
        }, deleteKeychainValue: delete), profileAdmission: admission, sdkFactory: {
            XCTFail("Local wipe must not construct or authenticate an SDK")
            throw ProfileRemovalStore.StoreError.unavailable
        })
    }

    func testFreshWipePersistsBeforeActualCleanupAndCompletesLast() async throws {
        let sdk = service()
        var paused: UUID?
        var resumed: UUID?
        var cleanupRan = false
        try await AppReset.withWipeAdmission(admission: admission, sdkService: sdk,
                                             pause: { paused = $0 }, resume: { resumed = $0 })
        { permitsRemote in
            let pending = try XCTUnwrap(self.store.pending())
            XCTAssertEqual(pending.scope, .walletWipe)
            XCTAssertTrue(permitsRemote)
            XCTAssertEqual(paused, pending.id)
            XCTAssertNil(resumed)
            try await sdk.forgetSessionAccess()
            cleanupRan = true
        }
        XCTAssertTrue(cleanupRan)
        XCTAssertEqual(paused, resumed)
        XCTAssertNil(try store.pending())
        XCTAssertNoThrow(try admission.snapshot())
    }

    func testStaleWipeRecoveryCannotStartANewWipe() async throws {
        for hasReplacement in [false, true] {
            let original = UUID()
            try store.begin(id: original, scope: .walletWipe)
            try store.complete(id: original, scope: .walletWipe)
            let replacement = UUID()
            if hasReplacement {
                try store.begin(id: replacement, scope: .walletWipe)
            }
            do {
                try await AppReset.withWipeAdmission(admission: admission, sdkService: service(), expectedPendingID: original,
                                                     pause: { _ in XCTFail("Stale recovery paused new work") }, resume: { _ in })
                { _ in
                    XCTFail("A stale recovery alert must not reset a replacement wallet")
                }
                XCTFail("Old recovery UUID was accepted")
            } catch ProfileRemovalStore.StoreError.changed {}
            XCTAssertEqual(try store.pending()?.id, hasReplacement ? replacement : nil)
            if hasReplacement {
                try store.complete(id: replacement, scope: .walletWipe)
            }
        }
    }

    func testFailedMarkerPersistenceNeverStartsDestruction() async throws {
        let failed = ProfileRemovalStore(url: directory.appendingPathComponent("pending.json"), write: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        admission = ProfileOperationAdmission(store: failed)
        var paused: UUID?
        var resumed: UUID?
        do {
            try await AppReset.withWipeAdmission(admission: admission, sdkService: service(),
                                                 pause: { paused = $0 }, resume: { resumed = $0 })
            { _ in
                XCTFail("Destruction ran without durable pending")
            }
            XCTFail("Persistence failure was hidden")
        } catch let error as CocoaError { XCTAssertEqual(error.code, .fileWriteNoPermission) }
        XCTAssertEqual(paused, resumed)
        XCTAssertNil(try failed.pending())
    }

    func testCredentialFailureRetainsWatermarksAndRetryIsLocalOnlyForSameID() async throws {
        var watermark = 41
        var failedID: UUID?
        let failing = service { _ in throw KeychainError.failedToDelete }
        do {
            try await AppReset.withWipeAdmission(admission: admission, sdkService: failing, pause: { _ in }, resume: { _ in }) { _ in
                failedID = try self.store.pending()?.id
                try await failing.forgetSessionAccess()
                watermark = 0
            }
            XCTFail("Credential failure was hidden")
        } catch {}
        XCTAssertEqual(watermark, 41)
        XCTAssertNotNil(failedID)
        XCTAssertEqual(try store.pending()?.id, failedID)
        let retry = service()
        try await AppReset.withWipeAdmission(admission: admission, sdkService: retry, pause: { _ in }, resume: { _ in }) { permitsRemote in
            XCTAssertFalse(permitsRemote)
            XCTAssertEqual(try self.store.pending()?.id, failedID)
            try await retry.forgetSessionAccess()
            watermark = 0
        }
        XCTAssertEqual(watermark, 0)
        XCTAssertNil(try store.pending())
    }

    func testPrivatePausedWorkerIsCancelledAndDrainedBeforeSdkWipe() async throws {
        let privateService = PrivatePaykitService(profileAdmission: admission)
        await privateService.setBackgroundWorkPaused(true)
        let entered = expectation(description: "Paused private operation entered")
        let worker = await privateService.profileTask {
            entered.fulfill()
            _ = await privateService.waitForBackgroundWork(generation: 0)
        }
        await fulfillment(of: [entered], timeout: 2)
        let wipe = Task {
            try await AppReset.withWipeAdmission(admission: admission, sdkService: service(), pause: { _ in }, resume: { _ in }) { _ in
                XCTAssertNotNil(try self.store.pending())
            }
        }
        let finished = expectation(description: "Revoked worker and wipe completed")
        Task {
            await worker?.value
            do { try await wipe.value } catch { XCTFail("Wipe failed: \(error)") }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertNil(try store.pending())
    }

    func testFailedFinalAcknowledgementRetainsPending() async throws {
        do {
            try await AppReset.withWipeAdmission(admission: admission, sdkService: service(), pause: { _ in }, resume: { _ in }) { _ in
                throw ProfileRemovalStore.StoreError.unavailable
            }
            XCTFail("Failed flush must not complete wipe")
        } catch ProfileRemovalStore.StoreError.unavailable {}
        XCTAssertEqual(try store.pending()?.scope, .walletWipe)
        XCTAssertThrowsError(try admission.snapshot())
    }

    func testCancellationAfterAcknowledgedCompletionDoesNotRecreatePending() async throws {
        let cancelling = ProfileRemovalStore(url: directory.appendingPathComponent("pending.json"), remove: {
            try FileManager.default.removeItem(at: $0)
            withUnsafeCurrentTask { $0?.cancel() }
        })
        admission = ProfileOperationAdmission(store: cancelling)
        let sdk = service()
        let operation = Task {
            try await AppReset.withWipeAdmission(admission: admission, sdkService: sdk, pause: { _ in }, resume: { _ in }) { _ in }
        }
        try await operation.value
        XCTAssertNil(try cancelling.pending())
    }
}
