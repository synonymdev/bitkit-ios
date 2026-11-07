@testable import Bitkit
import LDKNode
import XCTest

final class PublicPaykitAddressReservationTests: XCTestCase {
    private let alice = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
    private let bob = "pubky7don8zi885feihpjsyx7t53srod6z1n4xjiyaaxucpqarm6sh85o"

    @MainActor
    func testRemovalAndWipeDrainPublicDerivationBeforeClearingReservations() async throws {
        for kind in [ProfileOperationAdmission.Kind.removal, .walletWipe] {
            let defaults = try makeIsolatedDefaults()
            let wallet = AddressWallet()
            let held = expectation(description: "Public address derivation entered")
            var finish: CheckedContinuation<Void, Never>?
            var operations = wallet.operations
            operations.next = { type in
                let info = await wallet.next(addressType: type)
                await withCheckedContinuation {
                    finish = $0
                    held.fulfill()
                }
                return info
            }
            let store = PrivatePaykitAddressReservationStore(defaults: defaults, operations: operations)
            let allocation = Task { try await store.currentOrRotatedPublicAddress(for: alice) }
            await fulfillment(of: [held], timeout: 2)
            let admission = ProfileOperationAdmission.shared
            let removal = try admission.reserve(kind: kind, id: UUID(), expected: admission.snapshot())
            defer { admission.release(removal) }
            let drainStarted = expectation(description: "Removal drain entered")
            var drained = false
            let drain = Task {
                drainStarted.fulfill()
                try await admission.drain(before: removal)
                drained = true
            }
            await fulfillment(of: [drainStarted], timeout: 2)
            XCTAssertFalse(drained, "Cleanup cannot pass an outstanding LDK address continuation")
            finish?.resume()
            do {
                _ = try await allocation.value
                XCTFail("Revoked public allocation returned an assignment")
            } catch ProfileRemovalStore.StoreError.changed {
            } catch is CancellationError {}
            try await drain.value
            let snapshot = await store.backupSnapshot()
            XCTAssertEqual(snapshot, ["nativeSegwit": 0], "The revealed address must remain excluded before cleanup")
            let data = try XCTUnwrap(defaults.data(forKey: PrivatePaykitAddressReservationStore.defaultsKey))
            let ledger = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertTrue((ledger["publicAssignments"] as? [String: Any] ?? [:]).isEmpty)
            if kind == .walletWipe {
                await store.clear()
                XCTAssertNil(defaults.data(forKey: PrivatePaykitAddressReservationStore.defaultsKey))
            } else {
                try await store.clearContactAssignmentsForRemoval()
                let retained = await store.backupSnapshot()
                XCTAssertEqual(retained, snapshot)
            }
        }
    }

    @MainActor
    func testRemovalAndWipeDrainPublicPreparationAndPublicationCallbacks() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
        UserDefaults.standard.set(true, forKey: PublicPaykitService.publishingEnabledKey)
        UserDefaults.standard.set(true, forKey: PublicPaykitService.onchainPaymentOptionEnabledKey)
        UserDefaults.standard.set(false, forKey: PublicPaykitService.lightningPaymentOptionEnabledKey)
        UserDefaults.standard.set(false, forKey: PublicPaykitService.usdtPaymentOptionEnabledKey)
        for kind in [ProfileOperationAdmission.Kind.removal, .walletWipe] {
            for stage in ["reservation", "snapshot", "publication"] {
                PublicPaykitService.setCleanupPending(false)
                let store = try PrivatePaykitAddressReservationStore(defaults: makeIsolatedDefaults(), operations: AddressWallet().operations)
                let profile = PubkyProfileManager()
                profile.publicKey = alice
                profile.authState = .authenticated
                let session = try XCTUnwrap(profile.currentSession)
                let wallet = PublicActivityWallet(pubkyProfile: profile)
                wallet.reservations = store
                wallet.channels = []
                let held = expectation(description: "Public \(stage) callback entered")
                var finish: CheckedContinuation<Void, Never>?
                let hold = {
                    await withCheckedContinuation {
                        finish = $0
                        held.fulfill()
                    }
                }
                switch stage {
                case "reservation": wallet.afterAddressReservation = hold
                case "snapshot": wallet.afterEndpointSnapshot = hold
                default: wallet.afterEndpointWrite = hold
                }
                let publication = Task {
                    try await wallet.syncReceivePublicPaykitEndpoints(isSessionCurrent: { profile.currentSession == session })
                }
                await fulfillment(of: [held], timeout: 2)
                let admission = ProfileOperationAdmission.shared
                let removal = try admission.reserve(kind: kind, id: UUID(), expected: admission.snapshot())
                defer { admission.release(removal) }
                let drainStarted = expectation(description: "Removal drain entered")
                var drained = false
                let drain = Task {
                    drainStarted.fulfill()
                    try await admission.drain(before: removal)
                    drained = true
                }
                await fulfillment(of: [drainStarted], timeout: 2)
                XCTAssertFalse(drained, "Cleanup cannot pass the \(stage) callback")
                let pendingBeforeRelease = PublicPaykitService.isCleanupPending
                finish?.resume()
                do {
                    try await publication.value
                    XCTFail("Revoked public \(stage) returned success")
                } catch ProfileRemovalStore.StoreError.changed {
                } catch is CancellationError {}
                try await drain.value
                XCTAssertEqual(PublicPaykitService.isCleanupPending, pendingBeforeRelease,
                               "A revoked callback cannot change the successor's reconciliation state")
                XCTAssertEqual(wallet.publishedAddresses.count, stage == "publication" ? 1 : 0)
                await store.clear()
                let cleared = await store.backupSnapshot()
                XCTAssertNil(cleared)
            }
        }
    }

    func testPublicPrivateAndOrdinaryReceiveAddressesRemainSeparate() async throws {
        let defaults = try makeIsolatedDefaults()
        let wallet = AddressWallet()
        defaults.set(AddressWallet.address(0), forKey: "onchainAddress")
        let store = PrivatePaykitAddressReservationStore(defaults: defaults, operations: wallet.operations)

        let publicAddress = try await store.currentOrRotatedPublicAddress(for: alice)
        let privateAddress = try await store.currentOrRotatedAddress(for: bob)
        let receiveAddress = try await store.nextNonReservedReceiveAddress(addressType: .nativeSegwit)
        let publicAgain = try await store.currentOrRotatedPublicAddress(for: alice)
        let publicContact = await store.contactPublicKey(forReservedAddress: publicAddress)
        let privateContact = await store.contactPublicKey(forReservedAddress: privateAddress)

        XCTAssertEqual(Set([publicAddress, privateAddress, receiveAddress, AddressWallet.address(0)]).count, 4)
        XCTAssertEqual(defaults.string(forKey: "onchainAddress"), AddressWallet.address(0))
        XCTAssertEqual(publicAgain, publicAddress)
        XCTAssertNil(publicContact)
        XCTAssertEqual(privateContact, bob)
    }

    func testPublicReservationPersistsBeforePublicationAndSurvivesContactCleanup() async throws {
        let defaults = try makeIsolatedDefaults()
        let wallet = AddressWallet()
        let store = PrivatePaykitAddressReservationStore(defaults: defaults, operations: wallet.operations)
        let address = try await store.currentOrRotatedPublicAddress(for: alice)

        // No publication is acknowledged: a failed or uncertain write must not release the address.
        let restarted = PrivatePaykitAddressReservationStore(defaults: defaults, operations: wallet.operations)
        await restarted.clearContactAssignments()
        let retained = try await restarted.currentOrRotatedPublicAddress(for: alice)
        let unavailable = await restarted.isUnavailableForReusableReceive(address: address)
        XCTAssertEqual(retained, address)
        XCTAssertTrue(unavailable)
        let otherProfile = try await restarted.currentOrRotatedPublicAddress(for: bob)
        XCTAssertNotEqual(otherProfile, address)
    }

    func testRotationRetainsOldReservationsAndBackupExcludesThemAfterRestore() async throws {
        let defaults = try makeIsolatedDefaults()
        let wallet = AddressWallet()
        let store = PrivatePaykitAddressReservationStore(defaults: defaults, operations: wallet.operations)
        let first = try await store.currentOrRotatedPublicAddress(for: alice)
        await wallet.markUsed(first)
        let rotated = try await store.currentOrRotatedPublicAddress(for: alice)
        let firstUnavailable = await store.isUnavailableForReusableReceive(address: first)
        let rotatedUnavailable = await store.isUnavailableForReusableReceive(address: rotated)
        XCTAssertNotEqual(first, rotated)
        XCTAssertTrue(firstUnavailable)
        XCTAssertTrue(rotatedUnavailable)

        let snapshot = await store.backupSnapshot()
        let restoredWallet = AddressWallet()
        let restored = try PrivatePaykitAddressReservationStore(defaults: makeIsolatedDefaults(), operations: restoredWallet.operations)
        await restored.restoreBackup(snapshot)
        let receive = try await restored.nextNonReservedReceiveAddress(addressType: .nativeSegwit)
        let privateAddress = try await restored.currentOrRotatedAddress(for: bob)
        let publicAddress = try await restored.currentOrRotatedPublicAddress(for: alice)
        XCTAssertEqual(Set([first, rotated, receive, privateAddress, publicAddress]).count, 5)
    }

    func testUsageFailureDoesNotRotateOrReleasePublicReservation() async throws {
        let defaults = try makeIsolatedDefaults()
        let wallet = AddressWallet()
        let store = PrivatePaykitAddressReservationStore(defaults: defaults, operations: wallet.operations)
        let first = try await store.currentOrRotatedPublicAddress(for: alice)
        let before = await store.backupSnapshot()
        await wallet.failUsage(true)
        do {
            _ = try await store.currentOrRotatedPublicAddress(for: alice)
            XCTFail("An unreadable usage result cannot establish a reusable public address")
        } catch {
            XCTAssertEqual(error as? AddressWallet.Failure, .usage)
        }
        let after = await store.backupSnapshot()
        XCTAssertEqual(after, before)
        await wallet.failUsage(false)
        let retried = try await store.currentOrRotatedPublicAddress(for: alice)
        XCTAssertEqual(retried, first)
    }

    @MainActor
    func testLatePublicAddressSnapshotRetainsRepairAfterRotation() async throws {
        for refreshIfNeeded in [false, true] {
            for cancelAfterAdmission in [false, true] {
                try await assertLatePublicAddressSnapshotRetainsRepair(
                    refreshIfNeeded: refreshIfNeeded, cancelAfterAdmission: cancelAfterAdmission
                )
            }
        }
    }

    @MainActor
    private func assertLatePublicAddressSnapshotRetainsRepair(refreshIfNeeded: Bool, cancelAfterAdmission: Bool) async throws {
        snapshotAppDefaultsDomain()
        let lightning = Bitkit.LightningService.shared
        let previousCompletion = lightning.onchainActivityWillPersist
        defer { lightning.onchainActivityWillPersist = previousCompletion }
        UserDefaults.standard.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
        UserDefaults.standard.set(true, forKey: PublicPaykitService.publishingEnabledKey)
        UserDefaults.standard.set(true, forKey: PublicPaykitService.onchainPaymentOptionEnabledKey)
        UserDefaults.standard.set(false, forKey: PublicPaykitService.lightningPaymentOptionEnabledKey)
        UserDefaults.standard.set(false, forKey: PublicPaykitService.usdtPaymentOptionEnabledKey)
        let addresses = AddressWallet()
        let store = try PrivatePaykitAddressReservationStore(defaults: makeIsolatedDefaults(), operations: addresses.operations)
        let profile = PubkyProfileManager()
        profile.publicKey = alice
        profile.authState = .authenticated
        let session = try XCTUnwrap(profile.automaticPaykitSession)
        let wallet = PublicActivityWallet(pubkyProfile: profile)
        wallet.reservations = store
        wallet.channels = []
        let isCurrent = { profile.automaticPaykitSession == session }
        try await wallet.syncReceivePublicPaykitEndpoints(isSessionCurrent: isCurrent)
        let first = try XCTUnwrap(wallet.publishedAddresses.last)
        let captured = expectation(description: "Older public address snapshot")
        let admitted = cancelAfterAdmission ? expectation(description: "Older public address write") : nil
        var release: CheckedContinuation<Void, Never>?
        var finishWrite: CheckedContinuation<Void, Never>?
        defer {
            release?.resume()
            finishWrite?.resume()
        }
        wallet.afterEndpointSnapshot = {
            wallet.afterEndpointSnapshot = nil
            await withCheckedContinuation {
                release = $0
                captured.fulfill()
            }
        }
        let older = Task {
            try await wallet.publishPublicPaykitEndpoints(refreshIfNeeded: refreshIfNeeded, isSessionCurrent: isCurrent)
        }
        await fulfillment(of: [captured], timeout: 5)
        await addresses.markUsed(first)
        await wallet.refreshPublicPaykitAddressIfNeeded(isSessionCurrent: isCurrent)
        let rotated = try XCTUnwrap(wallet.publishedAddresses.last)
        XCTAssertNotEqual(rotated, first)
        XCTAssertFalse(PublicPaykitService.isCleanupPending)
        if cancelAfterAdmission {
            wallet.afterEndpointWrite = {
                wallet.afterEndpointWrite = nil
                await withCheckedContinuation {
                    finishWrite = $0
                    admitted?.fulfill()
                }
                try Task.checkCancellation()
            }
        }
        release?.resume()
        release = nil
        if cancelAfterAdmission {
            try await fulfillment(of: [XCTUnwrap(admitted)], timeout: 5)
            older.cancel()
            finishWrite?.resume()
            finishWrite = nil
            do {
                try await older.value
                XCTFail("Cancelled publication should propagate cancellation")
            } catch is CancellationError {}
        } else {
            try await older.value
        }
        XCTAssertEqual(wallet.publishedAddresses, [first, rotated, first])
        XCTAssertTrue(PublicPaykitService.isCleanupPending)
        try await PublicPaykitService.retryPendingEndpointReconciliation(
            wallet: wallet, isSessionCurrent: isCurrent, syncApp: {},
            applyEndpoints: { wallet.publishedAddresses.append(contentsOf: $0.map(\.value)) }
        )
        XCTAssertEqual(wallet.publishedAddresses.last, rotated)
        XCTAssertFalse(PublicPaykitService.isCleanupPending)
    }

    @MainActor
    func testPublicAddressSnapshotDoesNotAdoptRestoreDuringUsageLookup() async throws {
        let addresses = AddressWallet()
        let store = try PrivatePaykitAddressReservationStore(defaults: makeIsolatedDefaults(), operations: addresses.operations)
        let first = try await store.currentOrRotatedPublicAddressSnapshot(for: alice)
        first.withCurrentReservation { XCTAssertTrue($0) }
        let checkingUsage = expectation(description: "Public address usage lookup")
        var release: CheckedContinuation<Void, Never>?
        defer { release?.resume() }
        await addresses.beforeNextUsage {
            await withCheckedContinuation {
                release = $0
                checkingUsage.fulfill()
            }
        }
        let older = Task { try await store.currentOrRotatedPublicAddressSnapshot(for: alice) }
        await fulfillment(of: [checkingUsage], timeout: 5)
        await store.restoreBackup(store.backupSnapshot())
        release?.resume()
        release = nil
        let stale = try await older.value
        XCTAssertEqual(stale.address, first.address)
        stale.withCurrentReservation { XCTAssertFalse($0) }
        let current = try await store.currentOrRotatedPublicAddressSnapshot(for: alice)
        XCTAssertNotEqual(current.address, first.address)
        current.withCurrentReservation { XCTAssertTrue($0) }
        _ = try await store.currentOrRotatedAddress(for: bob)
        await store.clearContactAssignments()
        current.withCurrentReservation { XCTAssertTrue($0) }
        await store.clear()
        current.withCurrentReservation { XCTAssertFalse($0) }
    }

    @MainActor
    func testCancelledPublicReservationRetainsOnlyItsOriginalSessionsRepair() async throws {
        snapshotAppDefaultsDomain()
        let lightning = Bitkit.LightningService.shared
        let previousCompletion = lightning.onchainActivityWillPersist
        defer { lightning.onchainActivityWillPersist = previousCompletion }
        UserDefaults.standard.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
        UserDefaults.standard.set(true, forKey: PublicPaykitService.publishingEnabledKey)
        UserDefaults.standard.set(true, forKey: PublicPaykitService.onchainPaymentOptionEnabledKey)
        UserDefaults.standard.set(false, forKey: PublicPaykitService.lightningPaymentOptionEnabledKey)
        UserDefaults.standard.set(false, forKey: PublicPaykitService.usdtPaymentOptionEnabledKey)
        for replaceSession in [false, true] {
            PublicPaykitService.setCleanupPending(false)
            let addresses = AddressWallet()
            let store = try PrivatePaykitAddressReservationStore(defaults: makeIsolatedDefaults(), operations: addresses.operations)
            let profile = PubkyProfileManager()
            profile.publicKey = alice
            profile.authState = .authenticated
            let session = try XCTUnwrap(profile.currentSession)
            let wallet = PublicActivityWallet(pubkyProfile: profile)
            wallet.reservations = store
            wallet.afterAddressReservation = {
                if replaceSession {
                    try? await profile.signOut(performSessionCleanup: { throw PublicPaykitError.publicationFailed })
                    PublicPaykitService.setCleanupPending(false)
                }
                withUnsafeCurrentTask { $0?.cancel() }
            }
            let preparation = Task {
                try await wallet.publishPublicPaykitEndpoints(
                    refreshIfNeeded: false, isSessionCurrent: { !Task.isCancelled && profile.currentSession == session }
                )
            }
            do {
                try await preparation.value
                XCTFail("Cancelled publication must not write endpoints")
            } catch PubkyServiceError.sessionNotActive {
            } catch is CancellationError {
            } catch {
                XCTFail("Unexpected preparation error: \(error)")
            }
            XCTAssertEqual(PublicPaykitService.isCleanupPending, !replaceSession)
            XCTAssertEqual(profile.currentSession == session, !replaceSession)
            XCTAssertTrue(wallet.publishedAddresses.isEmpty)
            let retained = await store.backupSnapshot()
            XCTAssertNotNil(retained?["nativeSegwit"])
        }
    }

    @MainActor
    func testNodeReadinessCannotTransferPublicPreparationToAnotherSession() async throws {
        snapshotAppDefaultsDomain()
        let lightning = Bitkit.LightningService.shared
        let previousCompletion = lightning.onchainActivityWillPersist
        defer { lightning.onchainActivityWillPersist = previousCompletion }
        UserDefaults.standard.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
        UserDefaults.standard.set(true, forKey: PublicPaykitService.publishingEnabledKey)
        UserDefaults.standard.set(true, forKey: PublicPaykitService.onchainPaymentOptionEnabledKey)
        UserDefaults.standard.set(false, forKey: PublicPaykitService.lightningPaymentOptionEnabledKey)
        UserDefaults.standard.set(false, forKey: PublicPaykitService.usdtPaymentOptionEnabledKey)
        PublicPaykitService.setCleanupPending(false)
        let addresses = AddressWallet()
        let store = try PrivatePaykitAddressReservationStore(defaults: makeIsolatedDefaults(), operations: addresses.operations)
        let before = await store.backupSnapshot()
        let profile = PubkyProfileManager()
        profile.publicKey = alice
        profile.authState = .authenticated
        let session = try XCTUnwrap(profile.currentSession)
        let wallet = PublicActivityWallet(pubkyProfile: profile)
        wallet.reservations = store
        wallet.beforeNodeReady = {
            try? await profile.signOut(performSessionCleanup: { throw PublicPaykitError.publicationFailed })
            PublicPaykitService.setCleanupPending(false)
        }
        do {
            try await wallet.publishPublicPaykitEndpoints(refreshIfNeeded: true, isSessionCurrent: { profile.currentSession == session })
            XCTFail("An earlier publication cannot prepare for a replacement session")
        } catch PubkyServiceError.sessionNotActive {
        } catch {
            XCTFail("Unexpected publication error: \(error)")
        }
        let after = await store.backupSnapshot()
        XCTAssertEqual(after, before)
        XCTAssertFalse(PublicPaykitService.isCleanupPending)
        XCTAssertTrue(wallet.publishedAddresses.isEmpty)
        XCTAssertNotEqual(profile.currentSession, session)
    }

    @MainActor
    func testPersistedOnchainActivityRotatesPublicAddressWithoutContactsLightningOrReceiveChanges() async throws {
        snapshotAppDefaultsDomain()
        let lightning = Bitkit.LightningService.shared
        let previousCompletion = lightning.onchainActivityWillPersist
        defer { lightning.onchainActivityWillPersist = previousCompletion }
        UserDefaults.standard.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
        UserDefaults.standard.set(true, forKey: PublicPaykitService.publishingEnabledKey)
        UserDefaults.standard.set(true, forKey: PublicPaykitService.onchainPaymentOptionEnabledKey)
        UserDefaults.standard.set(false, forKey: PublicPaykitService.lightningPaymentOptionEnabledKey)
        UserDefaults.standard.set(false, forKey: PublicPaykitService.usdtPaymentOptionEnabledKey)
        let defaults = try makeIsolatedDefaults()
        let addresses = AddressWallet()
        defaults.set(AddressWallet.address(0), forKey: "onchainAddress")
        let store = PrivatePaykitAddressReservationStore(defaults: defaults, operations: addresses.operations)
        let profile = PubkyProfileManager()
        profile.publicKey = alice
        profile.authState = .authenticated
        let session = try XCTUnwrap(profile.automaticPaykitSession)
        let wallet = PublicActivityWallet(pubkyProfile: profile)
        wallet.reservations = store
        wallet.channels = []
        wallet.onchainAddress = AddressWallet.address(0)
        let isCurrent = { profile.automaticPaykitSession == session }
        let ordinaryInvoice = "lnbc-ordinary-receive-sentinel"
        wallet.bolt11 = ordinaryInvoice
        try await wallet.syncReceivePublicPaykitEndpoints(isSessionCurrent: isCurrent)
        let first = try XCTUnwrap(wallet.publishedAddresses.last)
        XCTAssertFalse(PublicPaykitService.isCleanupPending)
        var rawEventDelivered = false
        let completion = await lightning.deliverEvent(onchainReceivedEvent(address: first), onEvent: { _ in
            rawEventDelivered = true
        })
        XCTAssertTrue(rawEventDelivered)
        XCTAssertNotNil(completion)
        let usedBeforePersistence = try await store.needsPublicAddressRotation(for: alice)
        XCTAssertFalse(usedBeforePersistence)
        let persistenceStarted = expectation(description: "Activity persistence started")
        var finishPersistence: CheckedContinuation<Void, Never>?
        let persistence = Task {
            try await lightning.persistOnchainActivity(completion: completion) {
                await withCheckedContinuation {
                    finishPersistence = $0
                    persistenceStarted.fulfill()
                }
                await addresses.markUsed(first)
            }
        }
        await fulfillment(of: [persistenceStarted], timeout: 2)
        XCTAssertEqual(wallet.usageLookupCount, 0)
        XCTAssertEqual(wallet.publishedAddresses, [first])
        XCTAssertFalse(PublicPaykitService.isCleanupPending)
        finishPersistence?.resume()
        try await persistence.value

        let rotated = try XCTUnwrap(wallet.publishedAddresses.last)
        XCTAssertNotEqual(rotated, first)
        XCTAssertEqual(wallet.publishedAddresses.count, 2)
        XCTAssertEqual(wallet.onchainAddress, AddressWallet.address(0))
        XCTAssertEqual(wallet.bolt11, ordinaryInvoice)
        XCTAssertFalse(PublicPaykitService.isCleanupPending)
        let oldUnavailable = await store.isUnavailableForReusableReceive(address: first)
        let noContact = await store.contactPublicKey(forReservedAddress: first)
        XCTAssertTrue(oldUnavailable)
        XCTAssertNil(noContact)
        await wallet.refreshPublicPaykitAddressIfNeeded(isSessionCurrent: isCurrent)
        XCTAssertEqual(wallet.publishedAddresses.count, 2, "Unrelated activity must not republish an unused public address")

        await addresses.markUsed(rotated)
        wallet.failPublication = true
        await wallet.refreshPublicPaykitAddressIfNeeded(isSessionCurrent: isCurrent)
        XCTAssertTrue(PublicPaykitService.isCleanupPending)
        wallet.failPublication = false
        try await PublicPaykitService.retryPendingEndpointReconciliation(
            wallet: wallet, isSessionCurrent: isCurrent, syncApp: {},
            applyEndpoints: { endpoints in wallet.publishedAddresses.append(contentsOf: endpoints.map(\.value)) }
        )
        XCTAssertFalse(PublicPaykitService.isCleanupPending)
        XCTAssertNotEqual(wallet.publishedAddresses.last, rotated)
        XCTAssertEqual(wallet.onchainAddress, AddressWallet.address(0))
        XCTAssertEqual(wallet.bolt11, ordinaryInvoice)
    }

    @MainActor
    func testPublicAddressRotatesWhenItsTypeIsNoLongerMonitored() async throws {
        snapshotAppDefaultsDomain()
        let lightning = Bitkit.LightningService.shared
        let previousCompletion = lightning.onchainActivityWillPersist
        defer { lightning.onchainActivityWillPersist = previousCompletion }
        UserDefaults.standard.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
        UserDefaults.standard.set(true, forKey: PublicPaykitService.publishingEnabledKey)
        UserDefaults.standard.set(true, forKey: PublicPaykitService.onchainPaymentOptionEnabledKey)
        UserDefaults.standard.set(false, forKey: PublicPaykitService.lightningPaymentOptionEnabledKey)
        UserDefaults.standard.set(false, forKey: PublicPaykitService.usdtPaymentOptionEnabledKey)
        let defaults = try makeIsolatedDefaults()
        defaults.set("taproot", forKey: "selectedAddressType")
        defaults.set("nativeSegwit,taproot", forKey: "addressTypesToMonitor")
        defaults.set(AddressWallet.address(0), forKey: "onchainAddress")
        let store = PrivatePaykitAddressReservationStore(defaults: defaults, operations: AddressWallet().operations)
        let profile = PubkyProfileManager()
        profile.publicKey = alice
        profile.authState = .authenticated
        let session = try XCTUnwrap(profile.automaticPaykitSession)
        let wallet = PublicActivityWallet(pubkyProfile: profile)
        wallet.reservations = store
        wallet.channels = []
        wallet.onchainAddress = AddressWallet.address(0)
        let isCurrent = { profile.automaticPaykitSession == session }
        try await wallet.syncReceivePublicPaykitEndpoints(isSessionCurrent: isCurrent)
        let original = try XCTUnwrap(wallet.publishedAddresses.last)

        defaults.set("nativeSegwit", forKey: "selectedAddressType")
        await wallet.refreshPublicPaykitAddressIfNeeded(isSessionCurrent: isCurrent)
        XCTAssertEqual(wallet.publishedAddresses, [original])

        defaults.set("nativeSegwit", forKey: "addressTypesToMonitor")
        await wallet.refreshPublicPaykitAddressIfNeeded()
        let replacement = try XCTUnwrap(wallet.publishedAddresses.last)
        XCTAssertNotEqual(replacement, original)
        XCTAssertEqual(wallet.publishedAddresses.count, 2)
        XCTAssertFalse(PublicPaykitService.isCleanupPending)
        XCTAssertEqual(wallet.onchainAddress, AddressWallet.address(0))
        let originalUnavailable = await store.isUnavailableForReusableReceive(address: original)
        XCTAssertTrue(originalUnavailable)
        await wallet.refreshPublicPaykitAddressIfNeeded(isSessionCurrent: isCurrent)
        XCTAssertEqual(wallet.publishedAddresses, [original, replacement])
    }

    @MainActor
    func testOnchainActivityCompletionRejectsSessionAndConsentChangesAfterRawDelivery() async throws {
        snapshotAppDefaultsDomain()
        let lightning = Bitkit.LightningService.shared
        let previousCompletion = lightning.onchainActivityWillPersist
        defer { lightning.onchainActivityWillPersist = previousCompletion }
        for replacement in [false, true] {
            UserDefaults.standard.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
            UserDefaults.standard.set(true, forKey: PublicPaykitService.publishingEnabledKey)
            UserDefaults.standard.set(true, forKey: PublicPaykitService.onchainPaymentOptionEnabledKey)
            PublicPaykitService.setCleanupPending(false)
            let profile = PubkyProfileManager()
            profile.publicKey = alice
            profile.authState = .authenticated
            let wallet = PublicActivityWallet(pubkyProfile: profile)
            wallet.usageLookup = { true }
            let completion = await lightning.deliverEvent(onchainReceivedEvent(address: AddressWallet.address(1)), onEvent: { _ in
                if replacement {
                    profile.publicKey = self.bob
                } else {
                    UserDefaults.standard.set(false, forKey: PublicPaykitService.publishingEnabledKey)
                }
            })
            XCTAssertNotNil(completion)
            try await lightning.persistOnchainActivity(completion: completion, operation: {})
            XCTAssertEqual(wallet.usageLookupCount, 0)
            XCTAssertTrue(wallet.publishedAddresses.isEmpty)
            XCTAssertFalse(PublicPaykitService.isCleanupPending)
        }
    }

    @MainActor
    func testOnchainActivityCompletionRequiresSuccessfulPersistenceAndIgnoresLightningEvents() async throws {
        let lightning = Bitkit.LightningService.shared
        let previousCompletion = lightning.onchainActivityWillPersist
        defer { lightning.onchainActivityWillPersist = previousCompletion }
        var calls: [String] = []
        lightning.onchainActivityWillPersist = {
            calls.append("capture")
            return { calls.append("complete") }
        }
        let events: [LDKNode.Event] = [
            onchainReceivedEvent(address: AddressWallet.address(1)),
            .onchainTransactionConfirmed(
                txid: "confirmed", blockHash: "block", blockHeight: 1, confirmationTime: 1,
                details: .init(amountSats: 1000, inputs: [], outputs: [])
            ),
            .onchainTransactionReplaced(txid: "replaced", conflicts: ["replacement"]),
            .onchainTransactionReorged(txid: "reorged"),
            .onchainTransactionEvicted(txid: "evicted"),
        ]
        for event in events {
            for failsPersistence in [false, true] {
                calls = []
                let completion = await lightning.deliverEvent(event, onEvent: { _ in calls.append("raw") })
                XCTAssertNotNil(completion)
                XCTAssertEqual(calls, ["capture", "raw"])
                do {
                    try await lightning.persistOnchainActivity(completion: completion) {
                        calls.append("persist")
                        if failsPersistence {
                            throw AddressWallet.Failure.usage
                        }
                    }
                    XCTAssertFalse(failsPersistence)
                } catch {
                    XCTAssertTrue(failsPersistence)
                    XCTAssertEqual(error as? AddressWallet.Failure, .usage)
                }
                XCTAssertEqual(calls, failsPersistence ? ["capture", "raw", "persist"] : ["capture", "raw", "persist", "complete"])
            }
        }
        calls = []
        let completion = await lightning.deliverEvent(
            .paymentReceived(paymentId: nil, paymentHash: "lightning", amountMsat: 1000, customRecords: []),
            onEvent: { _ in calls.append("raw") }
        )
        XCTAssertNil(completion)
        XCTAssertEqual(calls, ["raw"])
    }

    @MainActor
    func testPublicOnchainActivityRejectsChangedConsentAndSessionAfterUsageLookup() async throws {
        snapshotAppDefaultsDomain()
        for replacement in [false, true] {
            UserDefaults.standard.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
            UserDefaults.standard.set(true, forKey: PublicPaykitService.publishingEnabledKey)
            UserDefaults.standard.set(true, forKey: PublicPaykitService.onchainPaymentOptionEnabledKey)
            PublicPaykitService.setCleanupPending(false)
            let profile = PubkyProfileManager()
            profile.publicKey = alice
            profile.authState = .authenticated
            let session = try XCTUnwrap(profile.automaticPaykitSession)
            let wallet = PublicActivityWallet(pubkyProfile: profile)
            wallet.usageLookup = {
                if replacement {
                    profile.publicKey = self.bob
                } else {
                    UserDefaults.standard.set(false, forKey: PublicPaykitService.publishingEnabledKey)
                }
                return true
            }
            await wallet.refreshPublicPaykitAddressIfNeeded { profile.automaticPaykitSession == session }
            XCTAssertTrue(wallet.publishedAddresses.isEmpty)
            XCTAssertFalse(PublicPaykitService.isCleanupPending)
        }
    }

    func testOlderBackupCannotReleaseKnownPublicExclusions() async throws {
        let defaults = try makeIsolatedDefaults()
        let wallet = AddressWallet()
        let store = PrivatePaykitAddressReservationStore(defaults: defaults, operations: wallet.operations)
        let first = try await store.currentOrRotatedPublicAddress(for: alice)
        await wallet.markUsed(first)
        let rotated = try await store.currentOrRotatedPublicAddress(for: alice)
        defaults.set([AddressWallet.address(8)], forKey: PrivatePaykitAddressReservationStore.legacyPublicAddressesKey)
        let originalFloor = await store.backupSnapshot()
        for incoming in [nil, ["nativeSegwit": UInt32(0)]] {
            defaults.set(first, forKey: "onchainAddress")
            await store.restoreBackup(incoming, legacyPublicAddresses: [AddressWallet.address(9)])
            let retainedFloor = await store.backupSnapshot()
            let retainedLegacy = await store.legacyPublicAddressesSnapshot()
            XCTAssertEqual(retainedFloor, originalFloor)
            XCTAssertEqual(retainedLegacy, [AddressWallet.address(8), AddressWallet.address(9)])
            XCTAssertNil(defaults.string(forKey: "onchainAddress"))
        }
        await store.restoreBackup(nil)
        let restarted = PrivatePaykitAddressReservationStore(defaults: defaults, operations: AddressWallet().operations)
        let receive = try await restarted.nextNonReservedReceiveAddress(addressType: .nativeSegwit)
        let publicAddress = try await restarted.currentOrRotatedPublicAddress(for: alice)
        XCTAssertEqual(Set([first, rotated, receive, publicAddress]).count, 4)
        let retainedLegacy = await restarted.legacyPublicAddressesSnapshot()
        XCTAssertEqual(retainedLegacy, [AddressWallet.address(8), AddressWallet.address(9)])
    }

    func testLegacyPublicAddressIsExcludedFromEveryAllocationAndBackupRoundTrips() async throws {
        for kind in ["public", "private", "receive"] {
            let defaults = try makeIsolatedDefaults()
            let wallet = AddressWallet()
            let store = PrivatePaykitAddressReservationStore(defaults: defaults, operations: wallet.operations)
            await store.restoreBackup(nil, legacyPublicAddresses: [AddressWallet.address(0)])
            let backup = await WalletBackupV1(
                version: 1, createdAt: 1, transfers: [], privatePaykitHighestReservedReceiveIndexByAddressType: nil,
                paykitSdkBackupState: nil, watchOnlyAccounts: nil, watchOnlyAccountAllocationState: nil,
                publicPaykitLegacyAddresses: store.legacyPublicAddressesSnapshot()
            )
            let decoded = try JSONDecoder().decode(WalletBackupV1.self, from: JSONEncoder().encode(backup))
            XCTAssertEqual(decoded.publicPaykitLegacyAddresses, [AddressWallet.address(0)])
            let address: String = switch kind {
            case "public": try await store.currentOrRotatedPublicAddress(for: alice)
            case "private": try await store.currentOrRotatedAddress(for: bob)
            default: try await store.nextNonReservedReceiveAddress(addressType: .nativeSegwit)
            }
            XCTAssertNotEqual(address, AddressWallet.address(0), kind)
            let floor = await store.backupSnapshot()
            XCTAssertNotNil(floor?["nativeSegwit"])
        }
    }

    @MainActor
    func testLegacyAndroidMetadataRestorePreservesExclusionsInNextWalletBackup() async throws {
        snapshotAppDefaultsDomain()
        let defaults = UserDefaults.standard
        let legacyAddress = AddressWallet.address(0)
        let retainedAddress = AddressWallet.address(9)
        defaults.removeObject(forKey: "privatePaykitAddressReservations")
        defaults.set([retainedAddress], forKey: PrivatePaykitAddressReservationStore.legacyPublicAddressesKey)
        let walletBackup = try JSONDecoder().decode(
            WalletBackupV1.self, from: Data(#"{"version":1,"createdAt":1,"transfers":[]}"#.utf8)
        )
        XCTAssertNil(walletBackup.privatePaykitHighestReservedReceiveIndexByAddressType)
        XCTAssertNil(walletBackup.publicPaykitLegacyAddresses)
        let store = PrivatePaykitAddressReservationStore(defaults: defaults, operations: AddressWallet().operations)
        await store.restoreBackup(
            walletBackup.privatePaykitHighestReservedReceiveIndexByAddressType,
            legacyPublicAddresses: walletBackup.publicPaykitLegacyAddresses
        )
        let metadata = try decodeAndroidMetadata(cache: ["onchainAddress": legacyAddress])
        SettingsViewModel.shared.restoreAppCacheData(metadata.cache)
        defaults.set("", forKey: "onchainAddress")

        let restarted = PrivatePaykitAddressReservationStore(defaults: defaults, operations: AddressWallet().operations)
        let retainedExclusions = await restarted.legacyPublicAddressesSnapshot()
        XCTAssertEqual(Set(retainedExclusions ?? []), Set([legacyAddress, retainedAddress]))
        let nextBackup = await WalletBackupV1(
            version: 1, createdAt: 2, transfers: [],
            privatePaykitHighestReservedReceiveIndexByAddressType: restarted.backupSnapshot(),
            paykitSdkBackupState: nil, watchOnlyAccounts: nil, watchOnlyAccountAllocationState: nil,
            publicPaykitLegacyAddresses: restarted.legacyPublicAddressesSnapshot()
        )
        let decoded = try JSONDecoder().decode(WalletBackupV1.self, from: JSONEncoder().encode(nextBackup))
        XCTAssertEqual(Set(decoded.publicPaykitLegacyAddresses ?? []), Set([legacyAddress, retainedAddress]))

        let restoredDefaults = try makeIsolatedDefaults()
        let restored = PrivatePaykitAddressReservationStore(defaults: restoredDefaults, operations: AddressWallet().operations)
        await restored.restoreBackup(
            decoded.privatePaykitHighestReservedReceiveIndexByAddressType,
            legacyPublicAddresses: decoded.publicPaykitLegacyAddresses
        )
        await restored.restoreBackup(nil)
        let restoredExclusions = await restored.legacyPublicAddressesSnapshot()
        XCTAssertEqual(Set(restoredExclusions ?? []), Set([legacyAddress, retainedAddress]))
    }

    @MainActor
    func testLegacyAndroidMetadataRestoreExcludesAddressFromEveryAllocation() async throws {
        snapshotAppDefaultsDomain()
        let defaults = UserDefaults.standard
        let legacyAddress = AddressWallet.address(0)
        let metadata = try decodeAndroidMetadata(cache: ["onchainAddress": legacyAddress])
        let walletBackup = try JSONDecoder().decode(
            WalletBackupV1.self, from: Data(#"{"version":1,"createdAt":1,"transfers":[]}"#.utf8)
        )

        for kind in ["receive", "private", "public"] {
            defaults.removeObject(forKey: "privatePaykitAddressReservations")
            defaults.removeObject(forKey: PrivatePaykitAddressReservationStore.legacyPublicAddressesKey)
            let store = PrivatePaykitAddressReservationStore(defaults: defaults, operations: AddressWallet().operations)
            await store.restoreBackup(
                walletBackup.privatePaykitHighestReservedReceiveIndexByAddressType,
                legacyPublicAddresses: walletBackup.publicPaykitLegacyAddresses
            )
            SettingsViewModel.shared.restoreAppCacheData(metadata.cache)
            defaults.set("", forKey: "onchainAddress")

            let restarted = PrivatePaykitAddressReservationStore(defaults: defaults, operations: AddressWallet().operations)
            let unavailable = await restarted.isUnavailableForReusableReceive(address: legacyAddress)
            XCTAssertTrue(unavailable, kind)
            let address: String = switch kind {
            case "private": try await restarted.currentOrRotatedAddress(for: bob)
            case "public": try await restarted.currentOrRotatedPublicAddress(for: alice)
            default: try await restarted.nextNonReservedReceiveAddress(addressType: .nativeSegwit)
            }
            XCTAssertNotEqual(address, legacyAddress, kind)
        }
    }

    @MainActor
    func testMetadataWithoutLegacyAddressKeepsExclusionsAndDoesNotBackUpLiveReceiveAddress() throws {
        snapshotAppDefaultsDomain()
        let defaults = UserDefaults.standard
        let retainedAddress = AddressWallet.address(9)
        let ordinaryAddress = AddressWallet.address(20)
        let caches: [[String: Any]] = [[:], ["onchainAddress": NSNull()], ["onchainAddress": ""]]

        for cache in caches {
            defaults.set([retainedAddress], forKey: PrivatePaykitAddressReservationStore.legacyPublicAddressesKey)
            defaults.set(ordinaryAddress, forKey: "onchainAddress")
            let metadata = try decodeAndroidMetadata(cache: cache)
            SettingsViewModel.shared.restoreAppCacheData(metadata.cache)
            XCTAssertEqual(defaults.stringArray(forKey: PrivatePaykitAddressReservationStore.legacyPublicAddressesKey), [retainedAddress])
            XCTAssertEqual(defaults.string(forKey: "onchainAddress"), ordinaryAddress)

            let nextCache = SettingsViewModel.shared.getAppCacheData()
            let encodedCache = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(nextCache)) as? [String: Any])
            XCTAssertNil(encodedCache["onchainAddress"])
        }
    }

    private func decodeAndroidMetadata(cache: [String: Any]) throws -> MetadataBackupV1 {
        let envelope: [String: Any] = [
            "version": 1,
            "createdAt": 1,
            "tagMetadata": [],
            "cache": cache,
        ]
        return try JSONDecoder().decode(MetadataBackupV1.self, from: JSONSerialization.data(withJSONObject: envelope))
    }

    func testConcurrentAllocationsUseSeparatePublicPrivateAndReceiveAddresses() async throws {
        let defaults = try makeIsolatedDefaults()
        let wallet = AddressWallet()
        let store = PrivatePaykitAddressReservationStore(defaults: defaults, operations: wallet.operations)
        async let publicAddress = store.currentOrRotatedPublicAddress(for: alice)
        async let privateAddress = store.currentOrRotatedAddress(for: alice)
        async let receiveAddress = store.nextNonReservedReceiveAddress(addressType: .nativeSegwit)
        let addresses = try await [publicAddress, privateAddress, receiveAddress]
        XCTAssertEqual(Set(addresses).count, 3)
        let publicContact = await store.contactPublicKey(forReservedAddress: addresses[0])
        let privateContact = await store.contactPublicKey(forReservedAddress: addresses[1])
        XCTAssertNil(publicContact)
        XCTAssertEqual(privateContact, alice)
    }

    func testExistingPrivateLedgerAndOlderBackupRemainCompatible() async throws {
        let defaults = try makeIsolatedDefaults()
        let wallet = AddressWallet()
        let oldLedger: [String: Any] = [
            "version": 1,
            "reservedReceiveIndexesByAddressType": ["nativeSegwit": [0]],
            "contactAssignments": [bob: ["addressType": "nativeSegwit", "receiveIndex": 0]],
            "contactAssignmentHistory": [:],
            "restoredReservedReceiveIndexCeilingsByAddressType": [:],
        ]
        try defaults.set(JSONSerialization.data(withJSONObject: oldLedger), forKey: "privatePaykitAddressReservations")
        let store = PrivatePaykitAddressReservationStore(defaults: defaults, operations: wallet.operations)
        let privateAddress = try await store.currentOrRotatedAddress(for: bob)
        let publicAddress = try await store.currentOrRotatedPublicAddress(for: alice)
        XCTAssertEqual(privateAddress, AddressWallet.address(0))
        XCTAssertNotEqual(publicAddress, privateAddress)

        let oldBackup = Data(#"{"version":1,"createdAt":1,"transfers":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(WalletBackupV1.self, from: oldBackup)
        XCTAssertNil(decoded.publicPaykitLegacyAddresses)
    }

    @MainActor
    private final class PublicActivityWallet: WalletViewModel {
        var reservations: PrivatePaykitAddressReservationStore?
        var publishedAddresses: [String] = []
        var failPublication = false
        var usageLookup: (() async throws -> Bool)?
        var usageLookupCount = 0
        var afterEndpointSnapshot: (() async -> Void)?
        var afterAddressReservation: (() async -> Void)?
        var beforeNodeReady: (() async -> Void)?
        var afterEndpointWrite: (() async throws -> Void)?

        override func refreshPublicPaykitEndpoints(
            forceRefreshBolt11: Bool = false, includeOnchain: Bool = true, includeLightning: Bool = true
        ) async throws -> PublicPaykitEndpoints {
            let snapshot = try await super.refreshPublicPaykitEndpoints(
                forceRefreshBolt11: forceRefreshBolt11, includeOnchain: includeOnchain, includeLightning: includeLightning
            )
            await afterEndpointSnapshot?()
            return snapshot
        }

        override func publicPaykitOnchainAddressSnapshot(for publicKey: String) async throws -> PrivatePaykitAddressReservationStore
            .PublicAddressSnapshot
        {
            let snapshot = try await XCTUnwrap(reservations).currentOrRotatedPublicAddressSnapshot(for: publicKey)
            await afterAddressReservation?()
            return snapshot
        }

        override func needsPublicPaykitAddressRotation(for publicKey: String) async throws -> Bool {
            usageLookupCount += 1
            if let usageLookup {
                return try await usageLookup()
            }
            return try await XCTUnwrap(reservations).needsPublicAddressRotation(for: publicKey)
        }

        override func publishPublicPaykitEndpoints(refreshIfNeeded: Bool, isSessionCurrent: @escaping @MainActor () -> Bool) async throws {
            let apply: ([PublicPaykitService.Endpoint]) async throws -> Void = { endpoints in
                if self.failPublication {
                    throw AddressWallet.Failure.usage
                }
                self.publishedAddresses.append(contentsOf: endpoints.map(\.value))
                try await self.afterEndpointWrite?()
            }
            if refreshIfNeeded {
                try await PublicPaykitService.syncPublishedEndpoints(
                    wallet: self, publish: true, isSessionCurrent: isSessionCurrent, syncApp: {}, applyEndpoints: apply
                )
            } else {
                try await PublicPaykitService.syncCurrentPublishedEndpoints(
                    wallet: self, isSessionCurrent: isSessionCurrent, syncApp: {}, applyEndpoints: apply
                )
            }
        }

        override func waitForNodeToRun(timeoutSeconds: Double = 10.0) async -> Bool {
            await beforeNodeReady?()
            return true
        }
    }

    private func onchainReceivedEvent(address: String) -> LDKNode.Event {
        .onchainTransactionReceived(
            txid: "received",
            details: .init(
                amountSats: 1000, inputs: [],
                outputs: [.init(scriptpubkey: "wallet", scriptpubkeyType: nil, scriptpubkeyAddress: address, value: 1000, n: 0)]
            )
        )
    }

    private actor AddressWallet {
        enum Failure: Error { case usage }
        private var nextIndex: UInt32 = 0
        private var used: Set<String> = []
        private var failsUsage = false
        private var usageStarted: (() async -> Void)?

        nonisolated var operations: PrivatePaykitAddressReservationStore.AddressOperations {
            .init(
                next: { addressType in await self.next(addressType: addressType) },
                resolve: { addressType, index in Self.address(index, addressType: addressType) },
                reveal: { _, index in await self.reveal(index) },
                isUsed: { try await self.isUsed($0) }
            )
        }

        static func address(_ index: UInt32, addressType: LDKNode.AddressType = .nativeSegwit) -> String {
            let isMainnet = Env.network == .bitcoin
            let prefix: String = switch addressType {
            case .legacy: isMainnet ? "1" : "m"
            case .nestedSegwit: isMainnet ? "3" : "2"
            case .nativeSegwit: isMainnet ? "bc1q" : "bcrt1q"
            case .taproot: isMainnet ? "bc1p" : "bcrt1p"
            }
            return "\(prefix)reserved\(index)"
        }

        func next(addressType: LDKNode.AddressType) -> Bitkit.LightningService.AddressDerivationInfo {
            defer { nextIndex += 1 }
            return .init(address: Self.address(nextIndex, addressType: addressType), index: nextIndex)
        }

        func reveal(_ index: UInt32) {
            nextIndex = max(nextIndex, index + 1)
        }

        func markUsed(_ address: String) {
            used.insert(address)
        }

        func failUsage(_ value: Bool) {
            failsUsage = value
        }

        func beforeNextUsage(_ operation: @escaping () async -> Void) {
            usageStarted = operation
        }

        func isUsed(_ address: String) async throws -> Bool {
            let operation = usageStarted
            usageStarted = nil
            await operation?()
            if failsUsage {
                throw Failure.usage
            }
            return used.contains(address)
        }
    }
}
