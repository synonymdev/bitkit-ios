@testable import Bitkit
import LDKNode
import XCTest

final class PublicPaykitAddressReservationTests: XCTestCase {
    private let alice = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
    private let bob = "pubky7don8zi885feihpjsyx7t53srod6z1n4xjiyaaxucpqarm6sh85o"

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
        let usedBeforePersistence = try await store.isCurrentPublicAddressUsed(for: alice)
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
        await wallet.refreshPublicPaykitAddressAfterOnchainActivity(isSessionCurrent: isCurrent)
        XCTAssertEqual(wallet.publishedAddresses.count, 2, "Unrelated activity must not republish an unused public address")

        await addresses.markUsed(rotated)
        wallet.failPublication = true
        await wallet.refreshPublicPaykitAddressAfterOnchainActivity(isSessionCurrent: isCurrent)
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
            await wallet.refreshPublicPaykitAddressAfterOnchainActivity { profile.automaticPaykitSession == session }
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

        override func publicPaykitOnchainAddress(for publicKey: String) async throws -> String {
            try await XCTUnwrap(reservations).currentOrRotatedPublicAddress(for: publicKey)
        }

        override func isPublicPaykitAddressUsed(for publicKey: String) async throws -> Bool {
            usageLookupCount += 1
            if let usageLookup {
                return try await usageLookup()
            }
            return try await XCTUnwrap(reservations).isCurrentPublicAddressUsed(for: publicKey)
        }

        override func publishPublicPaykitEndpoints(refreshIfNeeded: Bool, isSessionCurrent: @escaping @MainActor () -> Bool) async throws {
            try await PublicPaykitService.syncCurrentPublishedEndpoints(
                wallet: self, isSessionCurrent: isSessionCurrent, syncApp: {},
                applyEndpoints: { endpoints in
                    if self.failPublication {
                        throw AddressWallet.Failure.usage
                    }
                    self.publishedAddresses.append(contentsOf: endpoints.map(\.value))
                }
            )
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

        nonisolated var operations: PrivatePaykitAddressReservationStore.AddressOperations {
            .init(
                next: { _ in await self.next() },
                resolve: { _, index in Self.address(index) },
                reveal: { _, index in await self.reveal(index) },
                isUsed: { try await self.isUsed($0) }
            )
        }

        static func address(_ index: UInt32) -> String {
            "\(Env.network == .bitcoin ? "bc1q" : "bcrt1q")reserved\(index)"
        }

        func next() -> Bitkit.LightningService.AddressDerivationInfo {
            defer { nextIndex += 1 }
            return .init(address: Self.address(nextIndex), index: nextIndex)
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

        func isUsed(_ address: String) throws -> Bool {
            if failsUsage {
                throw Failure.usage
            }
            return used.contains(address)
        }
    }
}
