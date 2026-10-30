@testable import Bitkit
import Paykit
import XCTest

/// Writes made for one identity check, in the same locked SDK operation as the write, that the identity is still signed
/// in, so a sign-out and another identity's sign-in that land while the write waits make it write nothing.
final class PaykitSdkIdentityCheckTests: XCTestCase {
    private let contendedReads: [(read: @Sendable (PaykitSdkService) async throws -> String?, expected: String)] = [
        ({ try await $0.identityStatus()?.publicKey }, identityA),
        ({ try await $0.linkedPeers().first?.counterparty }, contactKey),
    ]

    func testIdentityAndPeerReadsRetryContentionAndReturnFreshState() async throws {
        for identity in [identityA, nil] {
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            sdk.identity = identity
            sdk.readErrors = [sharedStateBusy]
            let service = PaykitSdkService(sdkFactory: { sdk })

            let status = try await service.identityStatus()

            XCTAssertEqual(status?.publicKey, identity)
            XCTAssertEqual(status?.capability, identity == nil ? .signedOut : .publicOnly)
            let reads = await sdk.reads.count
            XCTAssertEqual(reads, 2)
            XCTAssertTrue(sdk.writes.isEmpty)
        }

        let sdk = IdentitySwitchingSdk(noPointer: .init())
        sdk.identity = identityA
        sdk.readErrors = [sharedStateBusy]
        sdk.peerState = .blocked
        let service = PaykitSdkService(sdkFactory: { sdk })

        let peers = try await service.linkedPeers()
        XCTAssertEqual(peers.map(\.counterparty), [contactKey])
        XCTAssertEqual(peers.map(\.state), [.blocked])
        let reads = await sdk.reads.count
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(sdk.writes.isEmpty)
    }

    func testIdentityAndPeerReadsDoNotRepeatExhaustedContentionOrOtherFailures() async throws {
        let cases: [(errors: [PaykitError], reads: Int)] = [
            ([sharedStateBusy, sharedStateBusy], 2),
            ([sharedStateBusy, .Identity(code: "identity_error", context: "Session changed")], 2),
            ([.Identity(code: "identity_error", context: "Session changed")], 1),
            ([.Storage(code: "storage_error", context: "State unavailable")], 1),
            ([.Transport(code: "transport_error", context: "Uncertain write")], 1),
            ([.ConcurrentUpdate(code: "concurrent_update", context: "Revision changed")], 1),
        ]
        for operation in contendedReads {
            for testCase in cases {
                let sdk = IdentitySwitchingSdk(noPointer: .init())
                sdk.readErrors = testCase.errors
                let service = PaykitSdkService(sdkFactory: { sdk })
                do {
                    _ = try await operation.read(service)
                    XCTFail("Expected the read to fail")
                } catch {
                    XCTAssertEqual(error.localizedDescription, testCase.errors.last?.localizedDescription)
                }
                let reads = await sdk.reads.count
                XCTAssertEqual(reads, testCase.reads)
                XCTAssertTrue(sdk.writes.isEmpty)
            }
        }
    }

    func testIdentityAndPeerReadCancellationPreventsContentionRetry() async throws {
        for operation in contendedReads {
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            sdk.readErrors = [sharedStateBusy]
            let service = PaykitSdkService(sdkFactory: { sdk })
            let read = Task { try await operation.read(service) }
            try await sdk.reads.waitForEntries(count: 1)
            read.cancel()

            do {
                _ = try await read.value
                XCTFail("Expected cancellation")
            } catch is CancellationError {}
            let reads = await sdk.reads.count
            XCTAssertEqual(reads, 1)
            XCTAssertTrue(sdk.writes.isEmpty)
        }
    }

    @MainActor
    func testBackgroundReadsRecheckPaymentAdmissionBeforeContentionRetry() async throws {
        let operations: [(PaykitSdkService) async throws -> Void] = [
            { _ = try await $0.identityStatus(priority: .background) },
            { _ = try await $0.linkedPeers(priority: .background) },
            { _ = try await $0.privateMessageSchedulingSnapshot(priority: .background) },
        ]
        for operation in operations {
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            sdk.readErrors = [sharedStateBusy]
            sdk.schedulingRead = {
                await sdk.reads.record()
                throw sharedStateBusy
            }
            let service = PaykitSdkService(sdkFactory: { sdk })
            let read = Task { try await operation(service) }
            try await sdk.reads.waitForEntries(count: 1)
            let payment = PaykitPaymentActivity.shared.begin()
            defer { PaykitPaymentActivity.shared.end(payment) }
            do {
                try await read.value
                XCTFail("A new payment must prevent the delayed acquisition retry")
            } catch PaykitPaymentRequestError.operationInProgress {}
            let attempts = await sdk.reads.count
            XCTAssertEqual(attempts, 1)
            XCTAssertTrue(sdk.writes.isEmpty)
        }
    }

    func testRevokedProfileReadsDoNotReenterSdkAfterContention() async throws {
        var operations: [(PaykitSdkService) async throws -> Void] = [
            { _ = try await $0.readPaymentRequests(counterparty: contactKey, expectedIdentity: nil) },
        ]
        for priority in [PaykitSdkOperationLock.Priority.ordered, .background] {
            operations += [
                { _ = try await $0.identityStatus(priority: priority) },
                { _ = try await $0.linkedPeers(priority: priority) },
                { _ = try await $0.privateMessageSchedulingSnapshot(priority: priority) },
            ]
        }
        for kind in [ProfileOperationAdmission.Kind.removal, .walletWipe] {
            for operation in operations {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let store = ProfileRemovalStore(url: directory.appendingPathComponent("pending.json"))
                let admission = ProfileOperationAdmission(store: store)
                let sdk = IdentitySwitchingSdk(noPointer: .init())
                sdk.readErrors = [sharedStateBusy]
                await sdk.readGate.close()
                sdk.paymentRequestRead = { _, _ in
                    await sdk.reads.record()
                    await sdk.readGate.wait()
                    throw sharedStateBusy
                }
                sdk.schedulingRead = {
                    await sdk.reads.record()
                    await sdk.readGate.wait()
                    throw sharedStateBusy
                }
                let service = PaykitSdkService(profileAdmission: admission, sdkFactory: { sdk })
                let read = Task { try await operation(service) }
                try await sdk.reads.waitForEntries(count: 1)
                let reservation = try admission.reserve(kind: kind, id: UUID(), expected: admission.snapshot())
                defer { admission.release(reservation) }
                let completedDrains = IdentityCheckCallLog()
                let drain = Task {
                    try await admission.drain(before: reservation)
                    await completedDrains.record()
                }
                await Task.yield()
                let prematureDrains = await completedDrains.count
                XCTAssertEqual(prematureDrains, 0, "The original native tail still owns admission")
                await sdk.readGate.open()
                let result = await read.result
                try await drain.value
                XCTAssertFalse(read.isCancelled, "Revocation must be checked even without task cancellation")
                XCTAssertThrowsError(try result.get()) { error in
                    guard case ProfileRemovalStore.StoreError.changed = error else {
                        return XCTFail("Expected revoked profile admission, got \(error)")
                    }
                }
                let attempts = await sdk.reads.count
                XCTAssertEqual(attempts, 1, "A revoked caller must not enter the SDK again")
                XCTAssertTrue(sdk.writes.isEmpty)
                XCTAssertNil(try store.pending())
            }
        }
    }

    func testPaymentRequestReadRetainsItsRuntimeThroughContentionAndFiltersRecords() async throws {
        let sdk = IdentitySwitchingSdk(noPointer: .init())
        let freshSdk = IdentitySwitchingSdk(noPointer: .init())
        let reads = IdentityCheckCallLog()
        let resets = IdentityCheckCallLog()
        let firstReadGate = IdentityCheckGate()
        await firstReadGate.close()
        defer { Task { await firstReadGate.open() } }
        let status = IdentityStatus(publicKey: identityA, capability: .privateLinkCapable)
        let bitkit = try paymentRequestRecord(appId: "bitkit")
        let server = try paymentRequestRecord(appId: "marketplace")
        sdk.paymentRequestRead = { counterparty, expectedIdentity in
            XCTAssertEqual(counterparty, contactKey)
            XCTAssertEqual(expectedIdentity, bareIdentityA)
            await reads.record()
            if await reads.count == 1 {
                await firstReadGate.wait()
                throw sharedStateBusy
            }
            let completedResets = await resets.count
            XCTAssertEqual(completedResets, 0)
            return PaymentRequestRead(identityStatus: status, paymentRequests: [server, bitkit])
        }
        let freshStatus = IdentityStatus(publicKey: identityB, capability: .publicOnly)
        freshSdk.paymentRequestRead = { _, expectedIdentity in
            XCTAssertNil(expectedIdentity)
            return PaymentRequestRead(identityStatus: freshStatus, paymentRequests: [])
        }
        var handlesCreated = 0
        let service = PaykitSdkService(sdkFactory: {
            handlesCreated += 1
            return handlesCreated == 1 ? sdk : freshSdk
        })
        let read = Task { try await service.readPaymentRequests(counterparty: contactKey, expectedIdentity: bareIdentityA) }
        try await reads.waitForEntries(count: 1)
        let resetStarted = expectation(description: "Runtime reset requested")
        let reset = Task {
            resetStarted.fulfill()
            await service.clearState()
            await resets.record()
        }
        await fulfillment(of: [resetStarted], timeout: 2)
        await firstReadGate.open()

        let result = try await read.value
        await reset.value
        XCTAssertEqual(result.identityStatus, status)
        XCTAssertEqual(result.paymentRequests.count, 1)
        let retained = try XCTUnwrap(result.paymentRequests.first)
        XCTAssertEqual(retained.counterparty, bitkit.counterparty)
        XCTAssertEqual(retained.paymentRequestId, bitkit.paymentRequestId)
        XCTAssertEqual(retained.proposalAppId, bitkit.proposalAppId)
        let attempts = await reads.count
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(handlesCreated, 1)
        let freshResult = try await service.readPaymentRequests(counterparty: contactKey, expectedIdentity: nil)
        XCTAssertEqual(freshResult.identityStatus, freshStatus)
        XCTAssertTrue(freshResult.paymentRequests.isEmpty)
        XCTAssertEqual(handlesCreated, 2)
        XCTAssertTrue(sdk.writes.isEmpty)
    }

    func testPaymentRequestReadRetriesOnlyOneAcquisitionFailure() async throws {
        let cases: [[Error]] = [
            [sharedStateBusy, sharedStateBusy],
            [sharedStateBusy, PaykitError.Identity(code: "identity_error", context: "Session changed")],
            [PaykitError.Identity(code: "identity_error", context: "Session changed")],
            [PaykitError.Storage(code: "storage_error", context: "State unavailable")],
            [PaykitError.Transport(code: "transport_error", context: "Uncertain write")],
            [PaykitError.ConcurrentUpdate(code: "concurrent_update", context: "Revision changed")],
            [CancellationError()],
        ]
        for errors in cases {
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            let reads = IdentityCheckCallLog()
            sdk.paymentRequestRead = { _, _ in
                await reads.record()
                let attempt = await reads.count
                throw errors[min(attempt - 1, errors.count - 1)]
            }
            let service = PaykitSdkService(sdkFactory: { sdk })
            do {
                _ = try await service.readPaymentRequests(counterparty: contactKey, expectedIdentity: nil)
                XCTFail("Expected the read to fail")
            } catch {
                let expected = errors[errors.count - 1]
                XCTAssertEqual(error.localizedDescription, expected.localizedDescription)
                XCTAssertEqual(error is CancellationError, expected is CancellationError)
            }
            let attempts = await reads.count
            XCTAssertEqual(attempts, errors.count)
            XCTAssertTrue(sdk.writes.isEmpty)
        }
    }

    func testIdentityAndPeerReadsRetainSdkOwnershipAcrossContentionRetry() async throws {
        for operation in contendedReads {
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            sdk.identity = identityA
            sdk.readErrors = [sharedStateBusy]
            let service = PaykitSdkService(sdkFactory: { sdk })
            let read = Task { try await operation.read(service) }
            try await sdk.reads.waitForEntries(count: 1)
            let signOut = Task { try await service.signOut() }

            let result = try await read.value
            try await signOut.value
            XCTAssertEqual(result, operation.expected)
            XCTAssertNil(sdk.identity)
            let reads = await sdk.reads.count
            XCTAssertEqual(reads, 2)
        }
    }

    func testCancelledPaymentRequestReadDrainsNativeWorkWithoutRetrying() async throws {
        for holdNativeRead in [false, true] {
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            let reads = IdentityCheckCallLog()
            let gate = IdentityCheckGate()
            if holdNativeRead {
                await gate.close()
            }
            sdk.paymentRequestRead = { _, _ in
                await reads.record()
                await gate.wait()
                throw sharedStateBusy
            }
            let service = PaykitSdkService(sdkFactory: { sdk })
            let read = Task { try await service.readPaymentRequests(counterparty: contactKey, expectedIdentity: nil) }
            try await reads.waitForEntries(count: 1)
            let admission = service.profileAdmission
            let contactsScope = try admission.capture()
            defer { admission.release(contactsScope) }
            read.cancel()
            let contacts = Task { try await admission.withScope(contactsScope) { try await service.contactRecords() } }
            if holdNativeRead {
                XCTAssertThrowsError(try admission.capture(), "Cancelled native work must drain before new admission")
                try await Task.sleep(for: .milliseconds(50))
                let overlappingReads = await sdk.contactRecordsStarted.count
                XCTAssertEqual(overlappingReads, 0)
            }
            await gate.open()
            let result = await read.result
            _ = try await contacts.value
            XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
            let attempts = await reads.count
            XCTAssertEqual(attempts, 1)
            let contactReads = await sdk.contactRecordsStarted.count
            XCTAssertEqual(contactReads, 1)
            _ = try await service.contactRecords()
            let freshReads = await sdk.contactRecordsStarted.count
            XCTAssertEqual(freshReads, 2)
        }
    }

    func testPaymentRequestReadRespectsWalletWipeAdmission() async throws {
        let sdk = IdentitySwitchingSdk(noPointer: .init())
        let reads = IdentityCheckCallLog()
        sdk.paymentRequestRead = { _, _ in
            await reads.record()
            return PaymentRequestRead(identityStatus: nil, paymentRequests: [])
        }
        let service = PaykitSdkService(sdkFactory: { sdk })
        let gate = IdentityCheckGate()
        await gate.close()
        let started = IdentityCheckCallLog()
        let wipe = Task {
            try await service.withWalletWipe {
                await started.record()
                await gate.wait()
            }
        }
        try await started.waitForEntries(count: 1)
        let rejected = expectation(description: "Read rejected during wallet wipe")
        let read = Task {
            defer { rejected.fulfill() }
            return try await service.readPaymentRequests(counterparty: contactKey, expectedIdentity: nil)
        }
        await fulfillment(of: [rejected], timeout: 2)
        let rejectedReads = await reads.count
        await gate.open()
        try await wipe.value
        let rejectedResult = await read.result
        XCTAssertThrowsError(try rejectedResult.get()) { error in
            guard case ProfileRemovalStore.StoreError.changed = error else {
                return XCTFail("Expected closed profile admission during wallet wipe, got \(error)")
            }
        }
        XCTAssertEqual(rejectedReads, 0)
        let result = try await service.readPaymentRequests(counterparty: contactKey, expectedIdentity: nil)
        XCTAssertNil(result.identityStatus)
        XCTAssertTrue(result.paymentRequests.isEmpty)
        let completedReads = await reads.count
        XCTAssertEqual(completedReads, 1)
    }

    func testSchedulingSnapshotKeepsSdkAdmissionAndRetriesAcquisitionOnce() async throws {
        let sdk = IdentitySwitchingSdk(noPointer: .init())
        let reads = IdentityCheckCallLog()
        let expected = Paykit.PrivateMessageSchedulingSnapshot(linkedPeers: [], pendingOutboundCounterparties: [contactKey])
        sdk.schedulingRead = {
            await reads.record()
            if await reads.count == 1 {
                throw sharedStateBusy
            }
            return expected
        }
        let service = PaykitSdkService(sdkFactory: { sdk })
        await sdk.contactRecordsGate.close()
        let holder = Task { try await service.contactRecords() }
        try await sdk.contactRecordsStarted.waitForEntries(count: 1)
        let snapshot = Task { try await service.privateMessageSchedulingSnapshot(priority: .background) }
        try await Task.sleep(for: .milliseconds(50))
        let overlappingReads = await reads.count
        await sdk.contactRecordsGate.open()
        _ = try await holder.value
        let result = try await snapshot.value
        XCTAssertEqual(overlappingReads, 0)
        XCTAssertTrue(result.linkedPeers.isEmpty)
        XCTAssertEqual(result.pendingOutboundCounterparties, expected.pendingOutboundCounterparties)
        let attempts = await reads.count
        XCTAssertEqual(attempts, 2)
    }

    func testObservationIsBoundToTheRequestedIdentity() async throws {
        let sdk = IdentitySwitchingSdk(noPointer: .init())
        sdk.identity = identityA
        let service = PaykitSdkService(sdkFactory: { sdk })
        let observation = try await service.observeState(priority: .background, expectedIdentity: bareIdentityA)
        XCTAssertEqual(observation.publicKey, identityA)
        XCTAssertEqual(observation.keyGeneration, 1)
        do {
            _ = try await service.observeState(priority: .background, expectedIdentity: identityB)
            XCTFail("Another identity's observation must not reach the display")
        } catch PubkyServiceError.identityChanged {}
        let reads = await sdk.observationStarted.count
        let contactReads = await sdk.contactRecordsStarted.count
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(contactReads, 0)
        XCTAssertTrue(sdk.writes.isEmpty)
    }

    func testCancelledObservationRetainsNativeOwnershipUntilCompletion() async throws {
        let sdk = IdentitySwitchingSdk(noPointer: .init())
        sdk.identity = identityA
        let service = PaykitSdkService(sdkFactory: { sdk })
        await sdk.observationGate.close()
        let observation = Task { try await service.observeState(priority: .background, expectedIdentity: identityA) }
        try await sdk.observationStarted.waitForEntries(count: 1)
        let admission = service.profileAdmission
        let contactsScope = try admission.capture()
        defer { admission.release(contactsScope) }
        observation.cancel()
        XCTAssertThrowsError(try admission.capture(), "New work is rejected until the cancelled native tail drains")
        let contacts = Task { try await admission.withScope(contactsScope) { try await service.contactRecords() } }
        try await Task.sleep(for: .milliseconds(50))
        let overlappingReads = await sdk.contactRecordsStarted.count
        await sdk.observationGate.open()
        let result = await observation.result
        let contactsResult = await contacts.result
        XCTAssertNoThrow(try contactsResult.get())
        XCTAssertEqual(overlappingReads, 0)
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        let completedReads = await sdk.contactRecordsStarted.count
        XCTAssertEqual(completedReads, 1)
        _ = try await service.contactRecords()
        let freshReads = await sdk.contactRecordsStarted.count
        XCTAssertEqual(freshReads, 2)
    }

    func testContactSaveForAnIdentityThatIsNoLongerSignedInWritesNothing() async throws {
        for signedIn in [identityB, nil] {
            for restorePrivateConnection in [false, true] {
                let message = "\(signedIn == nil ? "after a sign-out" : "with another identity signed in"), restore \(restorePrivateConnection)"
                let sdk = IdentitySwitchingSdk(noPointer: .init())
                sdk.identity = signedIn
                let service = PaykitSdkService(sdkFactory: { sdk })

                do {
                    _ = try await service.saveContact(
                        publicKey: contactKey,
                        label: "Alice",
                        restorePrivateConnection: restorePrivateConnection,
                        expectedIdentity: identityA
                    )
                    XCTFail("Expected the save to be refused \(message)")
                } catch PubkyServiceError.identityChanged {
                } catch {
                    XCTFail("Expected identityChanged \(message), got \(error)")
                }
                XCTAssertEqual(sdk.writes, [], "Nothing is written \(message)")
                XCTAssertEqual(sdk.contactReads, 0, "It stops before it reads the next identity's contact \(message)")
            }
        }
    }

    func testContactSaveForTheSignedInIdentitySaves() async throws {
        let sdk = IdentitySwitchingSdk(noPointer: .init())
        sdk.identity = identityA
        let service = PaykitSdkService(sdkFactory: { sdk })

        let saved = try await service.saveContact(publicKey: contactKey, label: "Alice", expectedIdentity: bareIdentityA)
        _ = try await service.saveContact(publicKey: contactKey, label: "Unbound")
        let imported = try await service.saveContacts(
            updates: [ContactUpdate(publicKey: contactKey, label: "Imported")],
            expectedIdentity: bareIdentityA
        )
        let readded = try await service.saveContact(
            publicKey: contactKey, label: "Readded", restorePrivateConnection: true, expectedIdentity: bareIdentityA
        )

        XCTAssertEqual(saved.label, "Alice", "The identity matches in either key form")
        XCTAssertEqual(imported.first?.label, "Imported")
        XCTAssertEqual(readded.label, "Readded")
        XCTAssertEqual(sdk.writes, ["save:Alice", "save:Unbound", "restore:1", "restore:1"])
        XCTAssertEqual(sdk.contactReads, 2, "Only ordinary updates look up the existing contact")
    }

    func testProfilePublicationForAnIdentityThatIsNoLongerSignedInWritesNothing() async throws {
        for signedIn in [identityB, nil] {
            let message = signedIn == nil ? "after a sign-out" : "with another identity signed in"
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            sdk.identity = signedIn
            let service = PaykitSdkService(sdkFactory: { sdk })

            do {
                _ = try await service.publishPaykitProfile(testProfile, expectedIdentity: identityA)
                XCTFail("Expected the publication to be refused \(message)")
            } catch PubkyServiceError.identityChanged {
            } catch {
                XCTFail("Expected identityChanged \(message), got \(error)")
            }
            XCTAssertEqual(sdk.writes, [], "Nothing is written \(message)")
        }

        let sdk = IdentitySwitchingSdk(noPointer: .init())
        sdk.identity = identityA
        let service = PaykitSdkService(sdkFactory: { sdk })
        _ = try await service.publishPaykitProfile(testProfile, expectedIdentity: bareIdentityA)
        _ = try await service.publishPaykitProfile(testProfile)
        XCTAssertEqual(sdk.writes, ["profile:Alice", "profile:Alice"], "A publication for the signed-in identity, or for none, publishes")
    }

    func testProfileAvatarUploadForAnIdentityThatIsNoLongerSignedInThrowsIdentityChanged() async throws {
        for signedIn in [identityB, nil] {
            let message = signedIn == nil ? "after a sign-out" : "with another identity signed in"
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            sdk.identity = signedIn
            let service = PaykitSdkService(sdkFactory: { sdk })

            do {
                _ = try await service.uploadAvatar(bytes: Data([1]), contentType: "image/jpeg", expectedIdentity: identityA)
                XCTFail("Expected the upload to be refused \(message)")
            } catch PubkyServiceError.identityChanged {
            } catch {
                XCTFail("Expected identityChanged \(message), got \(error)")
            }
            XCTAssertEqual(sdk.writes, [], "Nothing is written \(message)")
        }

        let sdk = IdentitySwitchingSdk(noPointer: .init())
        sdk.identity = identityA
        let service = PaykitSdkService(sdkFactory: { sdk })
        let uri = try await service.uploadAvatar(bytes: Data([1]), contentType: "image/jpeg", expectedIdentity: bareIdentityA)
        XCTAssertEqual(uri, "pubky://avatar")
        XCTAssertEqual(sdk.writes, ["upload"])
    }

    func testProfileDeletionRefusesActiveSubscriptionsInEitherRoleWithoutContacts() async throws {
        for role in [PaymentRequestLocalRole.payer, .payee] {
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            sdk.identity = identityA
            sdk.profileExists = true
            var request = try paymentRequestRecord(appId: "another-app")
            request.localRole = role
            request.state = .activeRecurring
            sdk.rawPaymentRequests = { [request] }
            let service = PaykitSdkService(sdkFactory: { sdk })

            let operations: [() async throws -> Void] = [
                { try await service.requireNoActiveSubscriptions(expectedIdentity: identityA) },
                { _ = try await service.removeContactsForProfile(publicKeys: []) },
                { _ = try await service.removeContactsForProfile(publicKeys: [identityB]) },
                { try await service.deletePaykitProfile(expectedIdentity: identityA) },
                { try await service.deleteConfirmedProfile(expectedIdentity: identityA, expectedRevision: "confirmed") },
            ]
            for operation in operations {
                do {
                    try await operation()
                    XCTFail("An active subscription must prevent profile cleanup even without its contact")
                } catch PubkyServiceError.activeSubscription {}
            }
            XCTAssertTrue(sdk.writes.isEmpty)
        }
    }

    func testProfileCleanupChecksAllSubscriptionsBeforeRemovingAnyContact() async throws {
        for endsAt in [nil, "invalid", "9999-01-01T00:00:00Z", "2000-01-01T00:00:00Z"] as [String?] {
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            sdk.identity = identityA
            sdk.profileExists = true
            var request = try paymentRequestRecord(appId: "another-app")
            request.state = .activeRecurring
            request.terms?.recurrence = PaymentRequestRecurrence(
                every: 1, unit: "month", startsAt: "1999-01-01T00:00:00Z", anchor: "1999-01-01T00:00:00Z", endsAt: endsAt
            )
            sdk.rawPaymentRequests = { [request] }
            let service = PaykitSdkService(sdkFactory: { sdk })
            let blocked = endsAt != "2000-01-01T00:00:00Z"
            let operations: [() async throws -> Void] = [
                { try await service.requireNoActiveSubscriptions(expectedIdentity: identityA) },
                { _ = try await service.removeContactsForProfile(publicKeys: [identityB]) },
                { _ = try await service.removeContactsForProfile(publicKeys: []) },
                { try await service.deletePaykitProfile(expectedIdentity: identityA) },
                { try await service.deleteConfirmedProfile(expectedIdentity: identityA, expectedRevision: "confirmed") },
            ]
            for operation in operations {
                do {
                    try await operation()
                    XCTAssertFalse(blocked)
                } catch let PubkyServiceError.activeSubscription(actualEnd) {
                    XCTAssertTrue(blocked)
                    XCTAssertEqual(actualEnd, endsAt.flatMap(PaykitPaymentRequest.parseDate))
                }
            }
            XCTAssertEqual(sdk.writes, blocked ? [] : ["remove-contacts:1", "delete-profile:test", "delete-profile:confirmed"])
        }
    }

    func testProfileRemovalOnlyReportsAnEndWhenEveryBlockingSubscriptionHasOne() async throws {
        let earlier = "2999-01-01T00:00:00Z"
        let later = "3000-01-01T00:00:00Z"
        let cases: [(ends: [String?], expected: String?)] = [
            ([earlier, later], later),
            ([later, earlier], later),
            ([earlier, nil], nil),
            (["invalid", later], nil),
            (["2000-01-01T00:00:00Z", later], later),
        ]
        for testCase in cases {
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            sdk.identity = identityA
            let requests = try testCase.ends.map { endsAt in
                var request = try paymentRequestRecord(appId: "another-app")
                request.state = .activeRecurring
                request.terms?.recurrence = PaymentRequestRecurrence(
                    every: 1, unit: "month", startsAt: "1999-01-01T00:00:00Z", anchor: "1999-01-01T00:00:00Z", endsAt: endsAt
                )
                return request
            }
            sdk.rawPaymentRequests = { requests }
            let service = PaykitSdkService(sdkFactory: { sdk })
            do {
                try await service.requireNoActiveSubscriptions(expectedIdentity: identityA)
                XCTFail("Every case contains a blocking subscription")
            } catch let PubkyServiceError.activeSubscription(endsAt) {
                XCTAssertEqual(endsAt, testCase.expected.flatMap(PaykitPaymentRequest.parseDate))
            }
            XCTAssertTrue(sdk.writes.isEmpty)
        }
    }

    func testSubscriptionReadFailureAndCancellationNeverAuthorizeProfileCleanup() async throws {
        for failure: Error in [sharedStateBusy, CancellationError()] {
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            sdk.identity = identityA
            sdk.profileExists = true
            sdk.rawPaymentRequests = { throw failure }
            let service = PaykitSdkService(sdkFactory: { sdk })
            let operations: [() async throws -> Void] = [
                { try await service.requireNoActiveSubscriptions(expectedIdentity: identityA) },
                { _ = try await service.removeContactsForProfile(publicKeys: [contactKey]) },
                { try await service.deletePaykitProfile(expectedIdentity: identityA) },
                { try await service.deleteConfirmedProfile(expectedIdentity: identityA, expectedRevision: "confirmed") },
            ]
            for operation in operations {
                do {
                    try await operation()
                    XCTFail("An unavailable subscription read must stop cleanup")
                } catch {
                    XCTAssertEqual(error.localizedDescription, failure.localizedDescription)
                }
            }
            XCTAssertTrue(sdk.writes.isEmpty)
        }
    }

    func testProfileDeletionChecksItsOwnerBeforeReadingOrRemovingTheProfile() async throws {
        for signedIn in [identityA, identityB, nil] {
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            sdk.identity = signedIn
            sdk.profileExists = true
            let service = PaykitSdkService(sdkFactory: { sdk })
            do {
                try await service.deletePaykitProfile(expectedIdentity: bareIdentityA)
                XCTAssertEqual(signedIn, identityA)
            } catch PubkyServiceError.identityChanged {
                XCTAssertNotEqual(signedIn, identityA)
            }
            XCTAssertEqual(sdk.profileReads, signedIn == identityA ? 1 : 0)
            XCTAssertEqual(sdk.writes, signedIn == identityA ? ["delete-profile:test"] : [])
            if signedIn == identityA {
                XCTAssertEqual(sdk.identitiesAtWrites, [identityA])
            }
        }
        let sdk = IdentitySwitchingSdk(noPointer: .init())
        sdk.identity = identityA
        let service = PaykitSdkService(sdkFactory: { sdk })
        try await service.deletePaykitProfile(expectedIdentity: identityA)
        XCTAssertTrue(sdk.writes.isEmpty, "Already-missing profile cleanup is idempotent")
    }

    /// Without a live session, a profile or contact avatar upload for the signed-in identity fails with the SDK's own
    /// error, as it did before uploads were bound to an identity, so Edit Profile does not show a payment request error.
    /// The payment request upload still reports `requestUnavailable`.
    func testProfileAvatarUploadWithoutALiveSessionReportsTheSdksOwnError() async throws {
        let sdk = IdentitySwitchingSdk(noPointer: .init())
        sdk.identity = identityA
        sdk.hasLiveSession = false
        let service = PaykitSdkService(sdkFactory: { sdk })

        do {
            _ = try await service.uploadAvatar(bytes: Data([1]), contentType: "image/jpeg", expectedIdentity: identityA)
            XCTFail("Expected the upload to fail without a live session")
        } catch let error as PaykitError {
            guard case .Identity = error else { return XCTFail("Expected the SDK's identity error, got \(error)") }
            XCTAssertEqual(error.localizedDescription, noLiveSessionError.localizedDescription)
            XCTAssertNotEqual(error.localizedDescription, PaykitPaymentRequestError.requestUnavailable.localizedDescription)
        } catch {
            XCTFail("Expected the SDK's own error, got \(error)")
        }

        do {
            _ = try await service.uploadProfileAvatar(bytes: Data([1]), contentType: "image/jpeg", expectedIdentity: identityA)
            XCTFail("Expected the payment request upload to be refused")
        } catch {
            XCTAssertEqual(error as? PaykitPaymentRequestError, .requestUnavailable, "The payment request upload is unchanged")
        }
        XCTAssertEqual(sdk.writes, [])
    }

    /// The caller checked its session and started the write, which waits for the SDK lock while a sign-out and another
    /// identity's sign-in land. Only then does the write get the lock, so it must check the identity there.
    func testWriteThatAnIdentityChangeOvertakesWhileItWaitsForTheSdkLockWritesNothing() async throws {
        let writes: [(name: String, write: @Sendable (PaykitSdkService) async throws -> Void, isRefusal: @Sendable (Error) -> Bool)] = [
            ("contact save", { service in
                _ = try await service.saveContact(publicKey: contactKey, label: "Alice", expectedIdentity: identityA)
            }, { error in
                if case .identityChanged? = error as? PubkyServiceError {
                    return true
                }
                return false
            }),
            ("contact batch save", { service in
                _ = try await service.saveContacts(updates: [ContactUpdate(publicKey: contactKey, label: "Alice")], expectedIdentity: identityA)
            }, { error in
                if case .identityChanged? = error as? PubkyServiceError {
                    return true
                }
                return false
            }),
            ("explicit contact re-add", { service in
                _ = try await service.saveContact(
                    publicKey: contactKey, label: "Alice", restorePrivateConnection: true, expectedIdentity: identityA
                )
            }, { error in
                if case .identityChanged? = error as? PubkyServiceError {
                    return true
                }
                return false
            }),
            ("profile avatar upload", { service in
                _ = try await service.uploadAvatar(bytes: Data([1]), contentType: "image/jpeg", expectedIdentity: identityA)
            }, { error in
                if case .identityChanged? = error as? PubkyServiceError {
                    return true
                }
                return false
            }),
            ("payment request upload", { service in
                _ = try await service.uploadProfileAvatar(bytes: Data([1]), contentType: "image/jpeg", expectedIdentity: identityA)
            }, { error in
                (error as? PaykitPaymentRequestError) == .requestUnavailable
            }),
            ("profile publication", { service in
                _ = try await service.publishPaykitProfile(testProfile, expectedIdentity: identityA)
            }, { error in
                if case .identityChanged? = error as? PubkyServiceError {
                    return true
                }
                return false
            }),
            ("profile deletion", { service in
                try await service.deletePaykitProfile(expectedIdentity: identityA)
            }, { error in
                if case .identityChanged? = error as? PubkyServiceError {
                    return true
                }
                return false
            }),
        ]
        for testCase in writes {
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            sdk.identity = identityA
            let service = PaykitSdkService(sdkFactory: { sdk })
            await sdk.contactRecordsGate.close()
            let lockHolder = Task { try await service.contactRecords() }
            try await sdk.contactRecordsStarted.waitForEntries(count: 1)

            let write = Task { try await testCase.write(service) }
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(sdk.writes, [], "\(testCase.name): the write waits for the SDK lock")
            sdk.identity = identityB

            await sdk.contactRecordsGate.open()
            _ = try await lockHolder.value
            switch await write.result {
            case .success:
                XCTFail("\(testCase.name): expected the write to be refused")
            case let .failure(error):
                XCTAssertTrue(testCase.isRefusal(error), "\(testCase.name): unexpected error \(error)")
            }
            XCTAssertEqual(sdk.writes, [], "\(testCase.name): nothing is written for the next identity")
        }
    }

    func testContactRestoreCancelledWhileWaitingForTheSdkLockWritesNothing() async throws {
        for bulk in [false, true] {
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            sdk.identity = identityA
            let service = PaykitSdkService(sdkFactory: { sdk })
            await sdk.contactRecordsGate.close()
            let lockHolder = Task { try await service.contactRecords() }
            try await sdk.contactRecordsStarted.waitForEntries(count: 1)

            let save = Task {
                if bulk {
                    _ = try await service.saveContacts(updates: [ContactUpdate(publicKey: contactKey, label: "Alice")], expectedIdentity: identityA)
                } else {
                    _ = try await service.saveContact(
                        publicKey: contactKey, label: "Alice", restorePrivateConnection: true, expectedIdentity: identityA
                    )
                }
            }
            try await Task.sleep(for: .milliseconds(50))
            save.cancel()
            await sdk.contactRecordsGate.open()
            _ = try await lockHolder.value

            do {
                try await save.value
                XCTFail("Expected queued contact restore to be cancelled")
            } catch is CancellationError {}
            XCTAssertTrue(sdk.writes.isEmpty)
        }
    }

    @MainActor
    func testImplicitRegistryPublicationUsesPrivateConsentAfterIdentityLookup() async throws {
        snapshotAppDefaultsDomain()
        for initiallyEnabled in [false, true] {
            UserDefaults.standard.set(initiallyEnabled, forKey: PrivatePaykitService.publishingEnabledKey)
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            sdk.identity = identityA
            sdk.supportsPrivatePayments = true
            let service = PaykitSdkService(sdkFactory: { sdk })
            await sdk.identityStatusGate.close()
            defer { Task { await sdk.identityStatusGate.open() } }
            let publication = Task { try await PublicPaykitService.syncPaykitApp(sdkService: service) }
            try await sdk.reads.waitForEntries(count: 1)

            UserDefaults.standard.set(!initiallyEnabled, forKey: PrivatePaykitService.publishingEnabledKey)
            await sdk.identityStatusGate.open()
            try await publication.value

            XCTAssertEqual(sdk.privatePaymentsAtWrites, [!initiallyEnabled])
        }
    }

    @MainActor
    func testExplicitRegistryConsentOverridesTheStoredPreference() async throws {
        snapshotAppDefaultsDomain()
        for enabled in [false, true] {
            UserDefaults.standard.set(!enabled, forKey: PrivatePaykitService.publishingEnabledKey)
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            sdk.identity = identityA
            sdk.supportsPrivatePayments = true
            let service = PaykitSdkService(sdkFactory: { sdk })

            try await PublicPaykitService.syncPaykitApp(privateSharingEnabled: enabled, sdkService: service)

            XCTAssertEqual(sdk.privatePaymentsAtWrites, [enabled])
        }
    }

    @MainActor
    func testSharingWritesRecheckTheOriginalSessionAfterWaitingForTheSdkLock() async throws {
        for registry in [false, true] {
            for replacementIdentity in [identityA, identityB] {
                let sdk = IdentitySwitchingSdk(noPointer: .init())
                sdk.identity = identityA
                let service = PaykitSdkService(sdkFactory: { sdk })
                var isCurrent = true
                await sdk.contactRecordsGate.close()
                let lockHolder = Task { try await service.contactRecords() }
                try await sdk.contactRecordsStarted.waitForEntries(count: 1)

                let write = Task {
                    if registry {
                        try await service.syncPaykitApp(privatePaymentsEnabled: false, isSessionCurrent: { isCurrent })
                    } else {
                        _ = try await service.syncPublicEndpoints([], isSessionCurrent: { isCurrent })
                    }
                }
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertEqual(sdk.writes, [])
                sdk.identity = replacementIdentity
                isCurrent = false
                await sdk.contactRecordsGate.open()
                _ = try await lockHolder.value
                do {
                    try await write.value
                    XCTFail("A superseded sharing change must not write, including a new session with the same key")
                } catch PubkyServiceError.sessionNotActive {}
                XCTAssertEqual(sdk.writes, [])
            }
        }
    }

    @MainActor
    func testLivePrivateCleanupRegistryWriteRejectsSessionReplacementWhileWaitingForSdkLock() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.removeObject(forKey: PrivatePaykitService.cacheStateKey)
        UserDefaults.standard.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
        for replacementIdentity in [identityA, identityB] {
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            sdk.identity = identityA
            sdk.peerState = nil
            let service = PaykitSdkService(sdkFactory: { sdk })
            let privateService = PrivatePaykitService()
            var isCurrent = true
            var passedFinalCleanupCheck = false
            let finalCleanupCheck = expectation(description: "Live cleanup checked ownership before registry sync")
            await sdk.linkedPeersGate.close()
            await sdk.contactRecordsGate.close()
            let cleanup = Task {
                try await privateService.removePublishedEndpoints(for: [contactKey], isSessionCurrent: {
                    if sdk.hasReadLinkedPeers, !passedFinalCleanupCheck {
                        passedFinalCleanupCheck = true
                        finalCleanupCheck.fulfill()
                    }
                    return isCurrent
                }, sdkService: service)
            }
            try await sdk.linkedPeersStarted.waitForEntries(count: 1)
            let lockHolder = Task { try await service.contactRecords() }
            try await Task.sleep(for: .milliseconds(50))
            await sdk.linkedPeersGate.open()
            try await sdk.contactRecordsStarted.waitForEntries(count: 1)
            await fulfillment(of: [finalCleanupCheck], timeout: 2)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(passedFinalCleanupCheck)
            XCTAssertTrue(sdk.writes.isEmpty)
            let registryAdmissions = await sdk.sharingStarted.count
            XCTAssertEqual(registryAdmissions, 0)

            sdk.identity = replacementIdentity
            isCurrent = false
            await sdk.contactRecordsGate.open()
            _ = try await lockHolder.value
            do {
                try await cleanup.value
                XCTFail("Live cleanup must retain its original session even when the replacement has the same key")
            } catch PubkyServiceError.sessionNotActive {}
            XCTAssertTrue(sdk.writes.isEmpty)
            let replacementAdmissions = await sdk.sharingStarted.count
            XCTAssertEqual(replacementAdmissions, 0)
        }
    }

    @MainActor
    func testLivePrivateCleanupRegistryWritePreservesCurrentAndUnownedCleanup() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.removeObject(forKey: PrivatePaykitService.cacheStateKey)
        UserDefaults.standard.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
        for guarded in [false, true] {
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            sdk.identity = identityA
            sdk.peerState = nil
            let service = PaykitSdkService(sdkFactory: { sdk })
            let privateService = PrivatePaykitService()
            let isSessionCurrent: (@MainActor () -> Bool)? = guarded ? { @MainActor in true } : nil
            try await privateService.removePublishedEndpoints(
                for: [contactKey], isSessionCurrent: isSessionCurrent, sdkService: service
            )
            XCTAssertTrue(sdk.hasReadLinkedPeers)
            XCTAssertEqual(sdk.writes, ["registry"])
            XCTAssertEqual(sdk.identitiesAtWrites, [identityA])
        }
    }

    @MainActor
    func testAdmittedLivePrivateCleanupRegistryWriteDrainsBeforeSignOutDespiteCancellation() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.removeObject(forKey: PrivatePaykitService.cacheStateKey)
        UserDefaults.standard.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
        let sdk = IdentitySwitchingSdk(noPointer: .init())
        sdk.identity = identityA
        sdk.peerState = nil
        let service = PaykitSdkService(sdkFactory: { sdk })
        let privateService = PrivatePaykitService()
        var isCurrent = true
        await sdk.sharingGate.close()
        let cleanup = Task {
            try await privateService.removePublishedEndpoints(for: [contactKey], isSessionCurrent: { isCurrent }, sdkService: service)
        }
        try await sdk.sharingStarted.waitForEntries(count: 1)
        isCurrent = false
        cleanup.cancel()
        let signOut = Task {
            try await ProfileOperationAdmission.shared.withSessionTransition {
                try await service.signOut()
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(sdk.identity, identityA)
        XCTAssertTrue(sdk.writes.isEmpty)
        await sdk.sharingGate.open()
        do {
            try await cleanup.value
            XCTFail("Cancelled sharing must not return success")
        } catch is CancellationError {}
        try await signOut.value
        XCTAssertEqual(sdk.writes, ["registry"])
        XCTAssertEqual(sdk.identitiesAtWrites, [identityA])
        XCTAssertNil(sdk.identity)
    }

    @MainActor
    func testAdmittedSharingWritesDrainBeforeSignOutDespiteCancellation() async throws {
        for registry in [false, true] {
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            sdk.identity = identityA
            let service = PaykitSdkService(sdkFactory: { sdk })
            var isCurrent = true
            await sdk.sharingGate.close()
            let write = Task {
                if registry {
                    try await service.syncPaykitApp(privatePaymentsEnabled: false, isSessionCurrent: { isCurrent })
                } else {
                    _ = try await service.syncPublicEndpoints([], isSessionCurrent: { isCurrent })
                }
            }
            try await sdk.sharingStarted.waitForEntries(count: 1)
            isCurrent = false
            write.cancel()
            let signOut = Task {
                try await ProfileOperationAdmission.shared.withSessionTransition {
                    try await service.signOut()
                }
            }
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(sdk.identity, identityA)
            await sdk.sharingGate.open()
            do {
                try await write.value
                XCTFail("Cancelled sharing must not return success")
            } catch is CancellationError {}
            try await signOut.value
            XCTAssertEqual(sdk.writes, [registry ? "registry" : "endpoints"])
            XCTAssertEqual(sdk.identitiesAtWrites, [identityA])
            XCTAssertNil(sdk.identity)
        }
    }

    func testSignOutWaitsForAtomicContactRestoration() async throws {
        for bulk in [false, true] {
            let sdk = IdentitySwitchingSdk(noPointer: .init())
            sdk.identity = identityA
            let service = PaykitSdkService(sdkFactory: { sdk })
            await sdk.restoreGate.close()
            let restore = Task {
                if bulk {
                    _ = try await service.saveContacts(updates: [ContactUpdate(publicKey: contactKey, label: "Alice")], expectedIdentity: identityA)
                } else {
                    _ = try await service.saveContact(
                        publicKey: contactKey, label: "Alice", restorePrivateConnection: true, expectedIdentity: identityA
                    )
                }
            }
            try await sdk.restoreStarted.waitForEntries(count: 1)

            let signOut = Task { try await service.signOut() }
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(sdk.identity, identityA)
            XCTAssertTrue(sdk.writes.isEmpty)
            await sdk.restoreGate.open()
            try await restore.value
            try await signOut.value

            XCTAssertNil(sdk.identity)
            XCTAssertEqual(sdk.writes, ["restore:1"])
            XCTAssertEqual(sdk.identitiesAtWrites, [identityA])
        }
    }

    /// A sign-out queues for the SDK lock right behind a contact save. The lock is handed over in order, so the save runs
    /// first and saves while its identity is signed in. Were its identity checked in a locked operation of its own, the
    /// sign-out would take the lock between that check and the save, and the save would land after it.
    func testSignOutQueuedBehindAContactSaveCannotLandBetweenItsCheckAndItsWrite() async throws {
        let sdk = IdentitySwitchingSdk(noPointer: .init())
        sdk.identity = identityA
        let service = PaykitSdkService(sdkFactory: { sdk })
        await sdk.contactRecordsGate.close()
        let lockHolder = Task { try await service.contactRecords() }
        try await sdk.contactRecordsStarted.waitForEntries(count: 1)

        let save = Task { try await service.saveContact(publicKey: contactKey, label: "Alice", expectedIdentity: identityA) }
        try await Task.sleep(for: .milliseconds(50))
        let signOut = Task { try await service.signOut() }
        try await Task.sleep(for: .milliseconds(50))

        await sdk.contactRecordsGate.open()
        _ = try await lockHolder.value
        try await signOut.value
        let saveResult = await save.result

        XCTAssertNil(sdk.identity, "The sign-out ran")
        XCTAssertNoThrow(try saveResult.get(), "The save got the lock first, while its identity was signed in")
        XCTAssertEqual(sdk.writes, ["save:Alice"])
        XCTAssertEqual(sdk.identitiesAtWrites, [identityA], "Nothing is written once the identity signed out")
    }

    private func paymentRequestRecord(appId: String) throws -> PaymentRequestRecord {
        try PaymentRequestRecord(
            counterparty: contactKey, paymentRequestId: "71300000-0000-4000-8000-000000000001",
            localRole: .payee, state: .proposed, proposalStreamItemId: 1,
            proposalOutboundMessageId: nil, proposalOutboundStatus: nil,
            proposalEventId: "71300000-0000-4000-8000-000000000002",
            proposalAppId: appId, proposalRecordedAt: nil, payerAppId: nil, executionClaimAppId: nil,
            terms: PaymentRequestTerms(
                amount: PaymentRequestAmount(value: "0.001", asset: "btc"),
                paymentReference: PaymentReference(text: "invoice-123"),
                proposalExpiresAt: nil, recurrence: nil, acceptedPaymentEndpointIdentifiers: ["btc-lightning-bolt11"],
                paymentEndpoints: nil, requiredAppId: "bitkit", conversion: nil, paymentDeadline: nil,
                metadata: PrivateJsonObject(text: "{}")
            ),
            acceptedEventId: nil, acceptedOutboundStatus: nil, acceptanceRecordedAt: nil,
            rejectedEventId: nil, rejectedOutboundStatus: nil,
            canceledEventId: nil, canceledOutboundStatus: nil,
            conversionQuotes: [], paymentProofs: [], lastStreamItemId: 42,
            lastOutboundMessageId: nil, lastOutboundStatus: nil,
            lastEventAt: "2026-10-20T12:00:00Z", invalidReason: nil
        )
    }
}

private let identityA = "pubky8qd4tbz3hyafi7h7hoqwd5hm7tsaz1n7txcyojmd4kxf9xp7mgro"
private let bareIdentityA = "8qd4tbz3hyafi7h7hoqwd5hm7tsaz1n7txcyojmd4kxf9xp7mgro"
private let identityB = "pubkyc1nbnzsfgm1g1rf9um6nh5mdtdhq8mz5i5o4r6g8x4qzi3uqhdmo"
private let contactKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
private let testProfile = PaykitProfile(displayName: "Alice", imageUri: nil, extraJson: nil)
private let sharedStateBusy = PaykitError.SharedStateBusy(code: "shared_state_busy", context: "Shared state is locked")
/// What the SDK reports for a blob upload without a live Pubky session.
private let noLiveSessionError = PaykitError.Identity(
    code: "identity_error",
    context: "cannot publish Paykit blob without an active Pubky session"
)

/// Holds every call that waits on it while closed.
private actor IdentityCheckGate {
    private var isOpen = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func close() {
        isOpen = false
    }

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

private struct IdentityCheckTimeout: Error, CustomStringConvertible {
    let description: String
}

/// Counts calls and lets a test wait until enough have started, failing instead of hanging.
private actor IdentityCheckCallLog {
    private(set) var count = 0

    func record() {
        count += 1
    }

    func waitForEntries(count expected: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while count < expected {
            guard ContinuousClock.now < deadline else {
                throw IdentityCheckTimeout(description: "Timed out waiting for \(expected) calls; saw \(count)")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// An SDK signed in as `identity`, which a test changes as a sign-out and another identity's sign-in would. A contact
/// records read waits on its gate, keeping the SDK lock meanwhile. It records each write that reaches it.
private final class IdentitySwitchingSdk: PaykitSdk, @unchecked Sendable {
    private let lock = NSLock()
    private var signedInIdentity: String?
    private var liveSession = true
    private var recordedWrites: [String] = []
    private var recordedIdentitiesAtWrites: [String?] = []
    private var recordedContactReads = 0
    private var completedLinkedPeersRead = false
    private var recordedProfileReads = 0
    private var storedProfileExists = false
    private var privateIdentity = false
    private var recordedPrivateCapabilities: [Bool] = []
    let identityStatusGate = IdentityCheckGate()
    let linkedPeersGate = IdentityCheckGate()
    let linkedPeersStarted = IdentityCheckCallLog()
    private var pendingReadErrors: [PaykitError] = []
    private var linkedPeerState: LinkedPeerState? = .linked
    let reads = IdentityCheckCallLog()
    let readGate = IdentityCheckGate()
    var paymentRequestRead: (String, String?) async throws -> PaymentRequestRead = { _, _ in
        PaymentRequestRead(identityStatus: nil, paymentRequests: [])
    }

    var rawPaymentRequests: () async throws -> [PaymentRequestRecord] = { [] }

    var schedulingRead: () async throws -> Paykit.PrivateMessageSchedulingSnapshot = {
        Paykit.PrivateMessageSchedulingSnapshot(linkedPeers: [], pendingOutboundCounterparties: [])
    }

    let contactRecordsGate = IdentityCheckGate()
    let contactRecordsStarted = IdentityCheckCallLog()
    let observationGate = IdentityCheckGate()
    let observationStarted = IdentityCheckCallLog()
    let restoreGate = IdentityCheckGate()
    let restoreStarted = IdentityCheckCallLog()
    let sharingGate = IdentityCheckGate()
    let sharingStarted = IdentityCheckCallLog()

    var identity: String? {
        get { lock.withLock { signedInIdentity } }
        set { lock.withLock { signedInIdentity = newValue } }
    }

    var hasLiveSession: Bool {
        get { lock.withLock { liveSession } }
        set { lock.withLock { liveSession = newValue } }
    }

    var supportsPrivatePayments: Bool {
        get { lock.withLock { privateIdentity } }
        set { lock.withLock { privateIdentity = newValue } }
    }

    var privatePaymentsAtWrites: [Bool] {
        lock.withLock { recordedPrivateCapabilities }
    }

    var readErrors: [PaykitError] {
        get { lock.withLock { pendingReadErrors } }
        set { lock.withLock { pendingReadErrors = newValue } }
    }

    var peerState: LinkedPeerState? {
        get { lock.withLock { linkedPeerState } }
        set { lock.withLock { linkedPeerState = newValue } }
    }

    var writes: [String] {
        lock.withLock { recordedWrites }
    }

    /// The identity signed in as each write landed.
    var identitiesAtWrites: [String?] {
        lock.withLock { recordedIdentitiesAtWrites }
    }

    var contactReads: Int {
        lock.withLock { recordedContactReads }
    }

    var hasReadLinkedPeers: Bool {
        lock.withLock { completedLinkedPeersRead }
    }

    var profileReads: Int {
        lock.withLock { recordedProfileReads }
    }

    var profileExists: Bool {
        get { lock.withLock { storedProfileExists } }
        set { lock.withLock { storedProfileExists = newValue } }
    }

    private func recordWrite(_ write: String) {
        lock.withLock {
            recordedWrites.append(write)
            recordedIdentitiesAtWrites.append(signedInIdentity)
        }
    }

    override func paymentRequests() async throws -> [PaymentRequestRecord] {
        try await rawPaymentRequests()
    }

    override func readPaymentRequests(counterparty: String, expectedIdentity: String?) async throws -> PaymentRequestRead {
        try await paymentRequestRead(counterparty, expectedIdentity)
    }

    override func privateMessageSchedulingSnapshot() async throws -> Paykit.PrivateMessageSchedulingSnapshot {
        try await schedulingRead()
    }

    override func identityStatus() async throws -> IdentityStatus? {
        await reads.record()
        await readGate.wait()
        await identityStatusGate.wait()
        let error = lock.withLock { pendingReadErrors.isEmpty ? nil : pendingReadErrors.removeFirst() }
        if let error {
            throw error
        }
        let capability: PubkyIdentityCapability = supportsPrivatePayments ? .privateLinkCapable : .publicOnly
        return IdentityStatus(publicKey: identity, capability: identity != nil && hasLiveSession ? capability : .signedOut)
    }

    override func linkedPeers() async throws -> [LinkedPeerRecord] {
        await linkedPeersStarted.record()
        await linkedPeersGate.wait()
        await reads.record()
        await readGate.wait()
        let error = lock.withLock { pendingReadErrors.isEmpty ? nil : pendingReadErrors.removeFirst() }
        if let error {
            throw error
        }
        lock.withLock { completedLinkedPeersRead = true }
        guard identity != nil, let peerState else { return [] }
        return [LinkedPeerRecord(
            counterparty: contactKey, state: peerState, lastSyncAt: nil, lastPrivateReceiveAt: nil,
            failureCount: 0, localRecoveryAttemptId: nil, localRecoveryMarkerCreatedAt: nil,
            localRecoveryMarkerLastError: nil, remoteRecoveryAttemptId: nil, remoteRecoveryMarkerObservedAt: nil
        )]
    }

    override func observeState() async throws -> PaykitStateObservation {
        guard let identity else { throw noLiveSessionError }
        await observationStarted.record()
        await observationGate.wait()
        return PaykitStateObservation(
            publicKey: identity, keyGeneration: 1, observedAt: "2027-01-15T08:00:00Z",
            contacts: [], linkedPeers: [], paymentRequests: [], receipts: []
        )
    }

    override func backupStateRevision() async throws -> String {
        "revision"
    }

    override func observedBackupStateRevision() throws -> ObservedBackupStateRevision? {
        nil
    }

    override func stateRevision() throws -> String? {
        nil
    }

    override func signOut() async throws -> IdentityStatus {
        identity = nil
        return IdentityStatus(publicKey: nil, capability: .signedOut)
    }

    override func contactRecords() async throws -> [ContactRecord] {
        await contactRecordsStarted.record()
        await contactRecordsGate.wait()
        return []
    }

    override func removeContactsAndBlockPeers(publicKeys: [String]) async throws -> [ContactRecord] {
        recordWrite("remove-contacts:\(publicKeys.count)")
        return publicKeys.map { Self.record(publicKey: $0, label: nil) }
    }

    override func contactRecord(publicKey: String) async throws -> ContactRecord? {
        lock.withLock { recordedContactReads += 1 }
        return Self.record(publicKey: publicKey, label: "Contact")
    }

    override func saveContact(update: ContactUpdate) async throws -> ContactRecord {
        recordWrite("save:\(update.label ?? "")")
        return Self.record(publicKey: update.publicKey, label: update.label)
    }

    override func saveContactsAndUnblockPeers(updates: [ContactUpdate]) async throws -> [ContactRecord] {
        await restoreStarted.record()
        await restoreGate.wait()
        recordWrite("restore:\(updates.count)")
        return updates.map { Self.record(publicKey: $0.publicKey, label: $0.label) }
    }

    override func uploadProfileAvatar(bytes: Data, contentType _: String) async throws -> PaykitBlobRecord {
        guard identity != nil, hasLiveSession else { throw noLiveSessionError }
        recordWrite("upload")
        return PaykitBlobRecord(
            publicKey: identity ?? "", path: "/pub/paykit/blobs/avatar.jpg", uri: "pubky://avatar",
            sizeBytes: UInt64(bytes.count), updatedAt: "2026-10-02T00:00:00Z"
        )
    }

    override func fetchPaykitProfile(publicKey _: String) async throws -> PaykitProfileRecord? {
        lock.withLock { recordedProfileReads += 1 }
        guard profileExists else { return nil }
        return PaykitProfileRecord(
            publicKey: identity ?? "", profile: testProfile, path: "/pub/paykit/profile.json",
            revision: "test", updatedAt: "2026-10-02T00:00:00Z"
        )
    }

    override func deletePaykitProfile(expectedRevision: String) async throws {
        recordWrite("delete-profile:\(expectedRevision)")
    }

    override func publishPaykitProfile(profile: PaykitProfile, expectedRevision _: String?) async throws -> PaykitProfileRecord {
        recordWrite("profile:\(profile.displayName ?? "")")
        return PaykitProfileRecord(
            publicKey: identity ?? "",
            profile: profile,
            path: "/pub/paykit/profile.json",
            revision: "test",
            updatedAt: "2026-10-02T00:00:00Z"
        )
    }

    override func publishPaykitApp(displayName _: String, capabilities: PaykitAppCapabilities) async throws -> PaykitAppRegistry {
        await sharingStarted.record()
        await sharingGate.wait()
        lock.withLock { recordedPrivateCapabilities.append(capabilities.privatePayments) }
        recordWrite("registry")
        return PaykitAppRegistry(keyGeneration: 1, noisePublicKey: nil, apps: [], defaultAppId: nil, defaultAppsByEndpoint: [:])
    }

    override func syncPublicEndpointsWithReceivingDetails(receivingDetails _: [PublicReceivingDetail]) async throws -> EndpointSyncReport {
        await sharingStarted.record()
        await sharingGate.wait()
        recordWrite("endpoints")
        return EndpointSyncReport(published: [], removed: [], failed: [])
    }

    private static func record(publicKey: String, label: String?) -> ContactRecord {
        ContactRecord(
            publicKey: publicKey, label: label, profile: nil,
            profileFetchedAt: nil, createdAt: "2026-10-02T00:00:00Z", updatedAt: "2026-10-02T00:00:00Z",
            publicContactMarkerStatus: .notPublished,
            publicContactPublishedAt: nil, publicContactRemovedAt: nil, publicContactLastError: nil
        )
    }
}
