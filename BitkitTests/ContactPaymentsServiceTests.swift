@testable import Bitkit
import Foundation
import XCTest

@MainActor
final class ContactPaymentsServiceTests: XCTestCase {
    func testContactPaymentsRemainOffUntilDefaultPublicationCompletes() throws {
        try withIsolatedDefaults { defaults in
            XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))
        }
    }

    func testConfirmedContactPaymentsReflectBothPublicationModes() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(true, forKey: ContactPaymentsService.confirmedPreferenceKey)
            XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))

            defaults.set(true, forKey: PublicPaykitService.publishingEnabledKey)
            XCTAssertTrue(ContactPaymentsService.isEnabled(defaults: defaults))

            defaults.set(false, forKey: PublicPaykitService.publishingEnabledKey)
            defaults.set(true, forKey: PrivatePaykitService.publishingEnabledKey)
            XCTAssertTrue(ContactPaymentsService.isEnabled(defaults: defaults))
        }
    }

    func testLegacyPaymentOptionsAreAlwaysReenabled() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(false, forKey: PublicPaykitService.lightningPaymentOptionEnabledKey)
            defaults.set(false, forKey: PublicPaykitService.onchainPaymentOptionEnabledKey)

            ContactPaymentsService.enableAllPaymentOptions(defaults: defaults)

            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.lightningPaymentOptionEnabledKey))
            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.onchainPaymentOptionEnabledKey))
        }
    }

    func testEnablingContactPaymentsPublishesPublicAndPrivateEndpoints() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            let operations = OperationsSpy()
            operations.onPreparePrivateEndpoints = {
                XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
                XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
                XCTAssertTrue(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey))
            }

            try await ContactPaymentsService.setEnabled(
                true,
                contactPublicKeys: ["contact-a", "contact-b"],
                canUsePrivatePayments: true,
                operations: operations.makeOperations(),
                defaults: defaults
            )

            XCTAssertEqual(operations.publicPublicationValues, [true])
            XCTAssertEqual(operations.privatePublications.count, 1)
            XCTAssertEqual(operations.privatePublications[0].contactPublicKeys, ["contact-a", "contact-b"])
            XCTAssertFalse(operations.privatePublications[0].requiresImmediatePublication)
            XCTAssertEqual(operations.calls, ["app:true", "public:true", "private:publish"])
            XCTAssertEqual(operations.privateRemovalCount, 0)
            XCTAssertEqual(operations.publicCleanupValues, [false])
            XCTAssertEqual(operations.privateCleanupValues, [false])
            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
            XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertTrue(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey))
            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.lightningPaymentOptionEnabledKey))
            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.onchainPaymentOptionEnabledKey))
        }
    }

    func testEnablingContactPaymentsWithoutPrivateCapabilityPublishesOnlyPublicEndpoints() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            defaults.set(true, forKey: PrivatePaykitService.cleanupPendingKey)
            let operations = OperationsSpy()

            try await ContactPaymentsService.setEnabled(
                true,
                contactPublicKeys: ["contact-a"],
                canUsePrivatePayments: false,
                operations: operations.makeOperations(),
                defaults: defaults
            )

            XCTAssertEqual(operations.publicPublicationValues, [true])
            XCTAssertTrue(operations.privatePublications.isEmpty)
            XCTAssertTrue(operations.privateCleanupValues.isEmpty)
            XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertTrue(ContactPaymentsService.isEnabled(defaults: defaults))
        }
    }

    func testEnablingContactPaymentsDefersUnavailablePrivatePublication() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            let service = PrivatePaykitService()
            let wallet = WalletViewModel()
            let contactPublicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
            let operations = OperationsSpy()
            operations.preparePrivateEndpoints = { contactPublicKeys, requireImmediatePublication in
                await service.prepareSavedContacts(
                    contactPublicKeys,
                    wallet: wallet,
                    requireImmediatePublication: requireImmediatePublication
                )
            }

            try await ContactPaymentsService.setEnabled(
                true,
                contactPublicKeys: [contactPublicKey],
                canUsePrivatePayments: true,
                operations: operations.makeOperations(),
                defaults: defaults
            )

            XCTAssertTrue(ContactPaymentsService.isEnabled(defaults: defaults))
            XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertEqual(operations.publicPublicationValues, [true])
            XCTAssertEqual(operations.privateRemovalCount, 0)
            let knownContacts = await service.knownSavedContactKeys
            XCTAssertEqual(knownContacts, [contactPublicKey])
        }
    }

    func testDisablingContactPaymentsRemovesBothEndpointTypes() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            defaults.set(true, forKey: PublicPaykitService.publishingEnabledKey)
            defaults.set(true, forKey: PrivatePaykitService.publishingEnabledKey)
            defaults.set(true, forKey: ContactPaymentsService.confirmedPreferenceKey)
            let operations = OperationsSpy()

            try await ContactPaymentsService.setEnabled(
                false,
                contactPublicKeys: ["contact-a"],
                canUsePrivatePayments: true,
                operations: operations.makeOperations(defaults: defaults),
                defaults: defaults
            )

            XCTAssertEqual(operations.publicPublicationValues, [false])
            XCTAssertEqual(operations.privateRemovalCount, 1)
            XCTAssertEqual(operations.calls, ["private:remove", "public:false"])
            XCTAssertEqual(operations.publicCleanupValues, [true, false])
            XCTAssertEqual(operations.privateCleanupValues, [true, false])
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertTrue(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey))
            XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))
        }
    }

    func testSwitchingToPublicOnlyMarksExistingPrivateEndpointsForCleanup() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            defaults.set(true, forKey: PrivatePaykitService.publishingEnabledKey)
            let operations = OperationsSpy()

            try await ContactPaymentsService.setEnabled(
                true,
                contactPublicKeys: ["contact-a"],
                canUsePrivatePayments: false,
                operations: operations.makeOperations(),
                defaults: defaults
            )

            XCTAssertEqual(operations.privateCleanupValues, [true])
            XCTAssertTrue(operations.privatePublications.isEmpty)
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertTrue(ContactPaymentsService.isEnabled(defaults: defaults))
        }
    }

    func testFailedPrivateSetupWithdrawsPublicEndpointAndRestoresDisabledState() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            defaults.set(true, forKey: PublicPaykitService.cleanupPendingKey)
            let operations = OperationsSpy()
            operations.privatePublicationFailures = [1]

            do {
                try await ContactPaymentsService.setEnabled(
                    true,
                    contactPublicKeys: ["contact-a"],
                    canUsePrivatePayments: true,
                    operations: operations.makeOperations(),
                    defaults: defaults
                )
                XCTFail("Expected private endpoint publication to fail")
            } catch {
                XCTAssertEqual(error as? TestError, .operationFailed)
            }

            XCTAssertEqual(operations.publicPublicationValues, [true, false])
            XCTAssertTrue(operations.calls.contains("public:true"))
            XCTAssertEqual(operations.privatePublications.count, 1)
            XCTAssertFalse(operations.privatePublications[0].requiresImmediatePublication)
            XCTAssertEqual(operations.privateRemovalCount, 1)
            XCTAssertEqual(operations.publicCleanupValues, [false, true])
            XCTAssertEqual(operations.privateCleanupValues, [false, false])
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertFalse(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey))
        }
    }

    func testFailedDisableKeepsContactPaymentsDisabledAndRetriesCleanup() async throws {
        for (privateFails, publicFails) in [(true, false), (false, true), (true, true)] {
            try await withIsolatedDefaultsAsync { defaults in
                defaults.set(true, forKey: PublicPaykitService.publishingEnabledKey)
                defaults.set(true, forKey: PrivatePaykitService.publishingEnabledKey)
                defaults.set(true, forKey: ContactPaymentsService.confirmedPreferenceKey)
                defaults.set(true, forKey: PublicPaykitService.cleanupPendingKey)
                let operations = OperationsSpy()
                operations.privateRemovalFailures = privateFails ? [1] : []
                operations.publicPublicationFailures = publicFails ? [1] : []

                do {
                    try await ContactPaymentsService.setEnabled(
                        false,
                        contactPublicKeys: ["contact-a"],
                        canUsePrivatePayments: true,
                        operations: operations.makeOperations(defaults: defaults),
                        defaults: defaults
                    )
                    XCTFail("Expected endpoint cleanup to fail")
                } catch {
                    XCTAssertEqual(error as? TestError, .operationFailed)
                }

                XCTAssertEqual(operations.publicPublicationValues, [false])
                XCTAssertEqual(operations.privateRemovalCount, 1)
                XCTAssertTrue(operations.privatePublications.isEmpty)
                XCTAssertEqual(operations.calls, ["private:remove", "public:false"])
                XCTAssertEqual(operations.publicCleanupValues, [true, publicFails])
                XCTAssertEqual(operations.privateCleanupValues, [true, privateFails])
                XCTAssertEqual(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey), publicFails)
                XCTAssertEqual(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey), privateFails)
                XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
                XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
                XCTAssertTrue(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey))
                XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))

                try await ContactPaymentsService.setEnabled(
                    false,
                    contactPublicKeys: ["contact-a"],
                    canUsePrivatePayments: true,
                    operations: operations.makeOperations(defaults: defaults),
                    defaults: defaults
                )

                XCTAssertEqual(operations.publicPublicationValues, [false, false])
                XCTAssertEqual(operations.privateRemovalCount, 2)
                XCTAssertTrue(operations.privatePublications.isEmpty)
                XCTAssertEqual(operations.publicCleanupValues, [true, publicFails, true, false])
                XCTAssertEqual(operations.privateCleanupValues, [true, privateFails, true, false])
                XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
                XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
                XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))
            }
        }
    }

    func testForegroundReconciliationSkipsBothPhasesOfActiveDisable() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            let operations = OperationsSpy()
            let privateRemovalStarted = expectation(description: "Private removal started")
            let publicRemovalStarted = expectation(description: "Public removal started")
            let (privateRemoval, finishPrivateRemoval) = AsyncStream<Void>.makeStream()
            let (publicRemoval, finishPublicRemoval) = AsyncStream<Void>.makeStream()
            defer {
                finishPrivateRemoval.finish()
                finishPublicRemoval.finish()
            }
            operations.onRemovePrivateEndpoints = {
                privateRemovalStarted.fulfill()
                for await _ in privateRemoval {}
            }
            operations.onSyncPublicEndpoints = { _ in
                publicRemovalStarted.fulfill()
                for await _ in publicRemoval {}
            }

            let disable = Task {
                try await ContactPaymentsService.setEnabled(
                    false, contactPublicKeys: [], canUsePrivatePayments: true,
                    operations: operations.makeOperations(defaults: defaults), defaults: defaults
                )
            }
            await fulfillment(of: [privateRemovalStarted], timeout: 2)
            XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))
            XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
            await ContactPaymentsService.reconcilePendingEndpoints {
                XCTFail("Foreground cleanup must not restart private withdrawal")
            }

            finishPrivateRemoval.finish()
            await fulfillment(of: [publicRemovalStarted], timeout: 2)
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
            await ContactPaymentsService.reconcilePendingEndpoints {
                XCTFail("Foreground cleanup must not duplicate public withdrawal")
            }

            finishPublicRemoval.finish()
            try await disable.value
            XCTAssertEqual(operations.calls, ["private:remove", "public:false"])
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
            var reconciled = false
            await ContactPaymentsService.reconcilePendingEndpoints { reconciled = true }
            XCTAssertTrue(reconciled)
        }
    }

    func testEnablingWaitsForSuccessfulOrFailedDisable() async throws {
        for removalFails in [false, true] {
            try await withIsolatedDefaultsAsync { defaults in
                let operations = OperationsSpy()
                operations.privateRemovalFailures = removalFails ? [1] : []
                let removalStarted = expectation(description: "Withdrawal started")
                let enableRequested = expectation(description: "Enable requested during withdrawal")
                let (removal, finishRemoval) = AsyncStream<Void>.makeStream()
                defer { finishRemoval.finish() }
                operations.onRemovePrivateEndpoints = {
                    removalStarted.fulfill()
                    for await _ in removal {}
                }

                let disable = Task {
                    try await ContactPaymentsService.setEnabled(
                        false, contactPublicKeys: [], canUsePrivatePayments: true,
                        operations: operations.makeOperations(defaults: defaults), defaults: defaults
                    )
                }
                await fulfillment(of: [removalStarted], timeout: 2)
                let enable = Task {
                    enableRequested.fulfill()
                    try await ContactPaymentsService.setEnabled(
                        true, contactPublicKeys: ["contact-a"], canUsePrivatePayments: true,
                        operations: operations.makeOperations(defaults: defaults), defaults: defaults
                    )
                }
                await fulfillment(of: [enableRequested], timeout: 2)
                XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))
                XCTAssertEqual(operations.calls, ["private:remove"])

                finishRemoval.finish()
                switch await disable.result {
                case .success:
                    XCTAssertFalse(removalFails)
                case let .failure(error):
                    XCTAssertTrue(removalFails)
                    XCTAssertEqual(error as? TestError, .operationFailed)
                }
                try await enable.value
                XCTAssertEqual(operations.calls, ["private:remove", "public:false", "app:true", "public:true", "private:publish"])
                XCTAssertTrue(ContactPaymentsService.isEnabled(defaults: defaults))
                XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.cleanupPendingKey))
                XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
            }
        }
    }

    func testForegroundReconciliationCoalescesAndSerializesSharingChanges() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            let operations = OperationsSpy()
            let reconciliationStarted = expectation(description: "Reconciliation started")
            let enableRequested = expectation(description: "Enable requested during reconciliation")
            let (reconciliation, finishReconciliation) = AsyncStream<Void>.makeStream()
            defer { finishReconciliation.finish() }
            var reconciliations = 0
            let retry = Task {
                await ContactPaymentsService.reconcilePendingEndpoints {
                    reconciliations += 1
                    reconciliationStarted.fulfill()
                    for await _ in reconciliation {}
                }
            }
            await fulfillment(of: [reconciliationStarted], timeout: 2)
            await ContactPaymentsService.reconcilePendingEndpoints { reconciliations += 1 }
            let enable = Task {
                enableRequested.fulfill()
                try await ContactPaymentsService.setEnabled(
                    true, contactPublicKeys: [], canUsePrivatePayments: true,
                    operations: operations.makeOperations(defaults: defaults), defaults: defaults
                )
            }
            await fulfillment(of: [enableRequested], timeout: 2)
            XCTAssertEqual(reconciliations, 1)
            XCTAssertTrue(operations.calls.isEmpty)

            finishReconciliation.finish()
            await retry.value
            try await enable.value
            XCTAssertTrue(ContactPaymentsService.isEnabled(defaults: defaults))
            XCTAssertEqual(operations.publicPublicationValues, [true])
        }
    }

    func testCancelledSharingChangeDoesNotPublishAfterReconciliation() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            let operations = OperationsSpy()
            let reconciliationStarted = expectation(description: "Reconciliation started")
            let enableRequested = expectation(description: "Enable requested during reconciliation")
            let (reconciliation, finishReconciliation) = AsyncStream<Void>.makeStream()
            defer { finishReconciliation.finish() }
            let retry = Task {
                await ContactPaymentsService.reconcilePendingEndpoints {
                    reconciliationStarted.fulfill()
                    for await _ in reconciliation {}
                }
            }
            await fulfillment(of: [reconciliationStarted], timeout: 2)
            let enable = Task {
                enableRequested.fulfill()
                try await ContactPaymentsService.setEnabled(
                    true, contactPublicKeys: [], canUsePrivatePayments: true,
                    operations: operations.makeOperations(defaults: defaults), defaults: defaults
                )
            }
            await fulfillment(of: [enableRequested], timeout: 2)
            enable.cancel()
            finishReconciliation.finish()
            await retry.value
            switch await enable.result {
            case .success:
                XCTFail("Cancelled sharing change must not publish")
            case let .failure(error):
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertTrue(operations.calls.isEmpty)
            XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))
            var reconciled = false
            await ContactPaymentsService.reconcilePendingEndpoints { reconciled = true }
            XCTAssertTrue(reconciled)
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "ContactPaymentsServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try body(defaults)
    }

    private func withIsolatedDefaultsAsync(_ body: (UserDefaults) async throws -> Void) async throws {
        let suiteName = "ContactPaymentsServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try await body(defaults)
    }

    private enum TestError: Error, Equatable {
        case operationFailed
    }

    private final class OperationsSpy {
        struct PrivatePublication {
            let contactPublicKeys: [String]
            let requiresImmediatePublication: Bool
        }

        var publicPublicationValues: [Bool] = []
        var privatePublications: [PrivatePublication] = []
        var privateRemovalCount = 0
        var publicCleanupValues: [Bool] = []
        var privateCleanupValues: [Bool] = []
        var calls: [String] = []
        var publicPublicationFailures: Set<Int> = []
        var privatePublicationFailures: Set<Int> = []
        var privateRemovalFailures: Set<Int> = []
        var onPreparePrivateEndpoints: (() -> Void)?
        var preparePrivateEndpoints: (([String], Bool) async -> Error?)?
        var onRemovePrivateEndpoints: (() async -> Void)?
        var onSyncPublicEndpoints: ((Bool) async -> Void)?

        func makeOperations(defaults: UserDefaults? = nil) -> ContactPaymentsService.Operations {
            ContactPaymentsService.Operations(
                syncPaykitApp: { enabled in
                    self.calls.append("app:\(enabled)")
                },
                syncPublicEndpoints: { publish in
                    self.calls.append("public:\(publish)")
                    self.publicPublicationValues.append(publish)
                    await self.onSyncPublicEndpoints?(publish)
                    if self.publicPublicationFailures.contains(self.publicPublicationValues.count) {
                        throw TestError.operationFailed
                    }
                },
                preparePrivateEndpoints: { contactPublicKeys, requiresImmediatePublication in
                    self.onPreparePrivateEndpoints?()
                    self.calls.append("private:publish")
                    self.privatePublications.append(
                        PrivatePublication(
                            contactPublicKeys: contactPublicKeys,
                            requiresImmediatePublication: requiresImmediatePublication
                        )
                    )
                    if let preparePrivateEndpoints = self.preparePrivateEndpoints {
                        return await preparePrivateEndpoints(contactPublicKeys, requiresImmediatePublication)
                    }
                    return self.privatePublicationFailures.contains(self.privatePublications.count) ? TestError.operationFailed : nil
                },
                removePrivateEndpoints: {
                    self.calls.append("private:remove")
                    self.privateRemovalCount += 1
                    await self.onRemovePrivateEndpoints?()
                    if self.privateRemovalFailures.contains(self.privateRemovalCount) {
                        throw TestError.operationFailed
                    }
                },
                setPublicCleanupPending: {
                    self.publicCleanupValues.append($0)
                    defaults?.set($0, forKey: PublicPaykitService.cleanupPendingKey)
                },
                setPrivateCleanupPending: {
                    self.privateCleanupValues.append($0)
                    defaults?.set($0, forKey: PrivatePaykitService.cleanupPendingKey)
                }
            )
        }
    }
}
