@testable import Bitkit
import Foundation
import XCTest

@MainActor
final class ContactPaymentsServiceTests: XCTestCase {
    func testContactPaymentsAreEnabledByDefaultBeforeConfirmation() throws {
        try withIsolatedDefaults { defaults in
            XCTAssertTrue(ContactPaymentsService.isEnabled(defaults: defaults))
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
            XCTAssertTrue(operations.privatePublications[0].requiresImmediatePublication)
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
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertTrue(ContactPaymentsService.isEnabled(defaults: defaults))
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
                operations: operations.makeOperations(),
                defaults: defaults
            )

            XCTAssertEqual(operations.publicPublicationValues, [false])
            XCTAssertEqual(operations.privateRemovalCount, 1)
            XCTAssertEqual(operations.publicCleanupValues, [false])
            XCTAssertEqual(operations.privateCleanupValues, [false])
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertTrue(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey))
            XCTAssertFalse(ContactPaymentsService.isEnabled(defaults: defaults))
        }
    }

    func testFailedPrivateEnableRestoresDisabledState() async throws {
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
            XCTAssertEqual(operations.privatePublications.count, 1)
            XCTAssertEqual(operations.privateRemovalCount, 1)
            XCTAssertEqual(operations.publicCleanupValues, [true])
            XCTAssertEqual(operations.privateCleanupValues, [false])
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
            XCTAssertFalse(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertFalse(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey))
        }
    }

    func testFailedPrivateDisableRestoresEnabledState() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            defaults.set(true, forKey: PublicPaykitService.publishingEnabledKey)
            defaults.set(true, forKey: PrivatePaykitService.publishingEnabledKey)
            defaults.set(true, forKey: ContactPaymentsService.confirmedPreferenceKey)
            defaults.set(true, forKey: PublicPaykitService.cleanupPendingKey)
            let operations = OperationsSpy()
            operations.privateRemovalFailures = [1]

            do {
                try await ContactPaymentsService.setEnabled(
                    false,
                    contactPublicKeys: ["contact-a"],
                    canUsePrivatePayments: true,
                    operations: operations.makeOperations(),
                    defaults: defaults
                )
                XCTFail("Expected private endpoint removal to fail")
            } catch {
                XCTAssertEqual(error as? TestError, .operationFailed)
            }

            XCTAssertEqual(operations.publicPublicationValues, [false, true])
            XCTAssertEqual(operations.privateRemovalCount, 1)
            XCTAssertEqual(operations.privatePublications.count, 1)
            XCTAssertEqual(operations.privatePublications[0].contactPublicKeys, ["contact-a"])
            XCTAssertTrue(operations.privatePublications[0].requiresImmediatePublication)
            XCTAssertEqual(operations.publicCleanupValues, [false, true])
            XCTAssertEqual(operations.privateCleanupValues, [true, false])
            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
            XCTAssertTrue(defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey))
            XCTAssertTrue(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey))
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
        var publicPublicationFailures: Set<Int> = []
        var privatePublicationFailures: Set<Int> = []
        var privateRemovalFailures: Set<Int> = []

        func makeOperations() -> ContactPaymentsService.Operations {
            ContactPaymentsService.Operations(
                syncPublicEndpoints: { publish in
                    self.publicPublicationValues.append(publish)
                    if self.publicPublicationFailures.contains(self.publicPublicationValues.count) {
                        throw TestError.operationFailed
                    }
                },
                preparePrivateEndpoints: { contactPublicKeys, requiresImmediatePublication in
                    self.privatePublications.append(
                        PrivatePublication(
                            contactPublicKeys: contactPublicKeys,
                            requiresImmediatePublication: requiresImmediatePublication
                        )
                    )
                    return self.privatePublicationFailures.contains(self.privatePublications.count) ? TestError.operationFailed : nil
                },
                removePrivateEndpoints: {
                    self.privateRemovalCount += 1
                    if self.privateRemovalFailures.contains(self.privateRemovalCount) {
                        throw TestError.operationFailed
                    }
                },
                setPublicCleanupPending: { self.publicCleanupValues.append($0) },
                setPrivateCleanupPending: { self.privateCleanupValues.append($0) }
            )
        }
    }
}
