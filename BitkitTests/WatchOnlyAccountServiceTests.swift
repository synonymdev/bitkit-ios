import Base58Swift
@testable import Bitkit
import LDKNode
import XCTest

final class WatchOnlyAccountServiceTests: XCTestCase {
    func testUnsignedClaimContainsExactAccountMetadata() throws {
        let rawXpub = Data((0 ..< WatchOnlyAccountClaimCodec.serializedXpubLength).map { UInt8($0 + 1) })
        let record = makeRecord(accountIndex: 42, xpub: base58CheckEncode(rawXpub))

        let payload = try WatchOnlyAccountClaimCodec.encode(record: record)

        XCTAssertEqual(payload.count, 84)
        XCTAssertEqual(payload.count, WatchOnlyAccountClaimCodec.payloadLength)
        XCTAssertEqual(payload[0], WatchOnlyAccountClaimCodec.version)
        XCTAssertEqual(payload[5], WatchOnlyAccountClaimCodec.nativeSegwitAddressType)
        XCTAssertEqual(payload.subdata(in: 6 ..< 84), rawXpub)

        let accountIndex = payload[1 ..< 5].reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(accountIndex, 42)
    }

    func testUnsignedClaimRejectsInvalidBase58CheckChecksum() throws {
        let rawXpub = Data((0 ..< WatchOnlyAccountClaimCodec.serializedXpubLength).map { UInt8($0 + 1) })
        let validXpub = base58CheckEncode(rawXpub)
        let invalidXpub = String(validXpub.dropLast()) + (validXpub.last == "1" ? "2" : "1")

        XCTAssertThrowsError(try WatchOnlyAccountClaimCodec.encode(record: makeRecord(accountIndex: 1, xpub: invalidXpub))) {
            XCTAssertEqual($0 as? WatchOnlyAccountError, .invalidExtendedPublicKey)
        }
    }

    func testRestoreDoesNotLowerAllocatorHighWaterMark() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(walletIndex: 0, requestFingerprint: "first", defaults: defaults), 1)
        try WatchOnlyAccountStore.completeAllocation(walletIndex: 0, requestFingerprint: "first", defaults: defaults)
        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(walletIndex: 0, requestFingerprint: "second", defaults: defaults), 2)
        try WatchOnlyAccountStore.completeAllocation(walletIndex: 0, requestFingerprint: "second", defaults: defaults)

        let restored = makeRecord(accountIndex: 1, xpub: base58CheckEncode(Data(repeating: 1, count: 78)))
        try WatchOnlyAccountStore.restore([restored], defaults: defaults)

        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(walletIndex: 0, requestFingerprint: "next", defaults: defaults), 3)
    }

    func testRestoreWithoutAllocatorClearsPendingReservationAndPreservesHighWaterMark() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "stale-pending",
            defaults: defaults
        ), 1)

        try WatchOnlyAccountStore.restore([], defaults: defaults)

        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "stale-pending",
            defaults: defaults
        ), 2)
    }

    func testBackupRestoresPendingReservationAndHighWaterMark() throws {
        let sourceSuiteName = "WatchOnlyAccountServiceTests.source.\(UUID().uuidString)"
        let restoredSuiteName = "WatchOnlyAccountServiceTests.restored.\(UUID().uuidString)"
        let sourceDefaults = try XCTUnwrap(UserDefaults(suiteName: sourceSuiteName))
        let restoredDefaults = try XCTUnwrap(UserDefaults(suiteName: restoredSuiteName))
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceSuiteName)
            restoredDefaults.removePersistentDomain(forName: restoredSuiteName)
        }

        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "pending",
            defaults: sourceDefaults
        ), 1)
        let snapshot = try WatchOnlyAccountStore.backupSnapshot(defaults: sourceDefaults)

        try WatchOnlyAccountStore.restore(
            snapshot.accounts,
            allocationState: snapshot.allocationState,
            defaults: restoredDefaults
        )

        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "pending",
            defaults: restoredDefaults
        ), 1)
        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "next",
            defaults: restoredDefaults
        ), 2)
    }

    func testRestorePreservesExactLocalPendingReservationForRetry() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "pending",
            defaults: defaults
        ), 1)
        let snapshot = try WatchOnlyAccountStore.backupSnapshot(defaults: defaults)

        try WatchOnlyAccountStore.restore(
            snapshot.accounts,
            allocationState: snapshot.allocationState,
            defaults: defaults
        )

        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "pending",
            defaults: defaults
        ), 1)
        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "next",
            defaults: defaults
        ), 2)
    }

    func testRestoreRejectsDivergentReservationForLocalPendingRequest() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for index in 1 ... 6 {
            let requestFingerprint = "completed-\(index)"
            XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
                walletIndex: 0,
                requestFingerprint: requestFingerprint,
                defaults: defaults
            ), UInt32(index))
            try WatchOnlyAccountStore.completeAllocation(
                walletIndex: 0,
                requestFingerprint: requestFingerprint,
                defaults: defaults
            )
        }
        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "pending",
            defaults: defaults
        ), 7)

        try WatchOnlyAccountStore.restore(
            [],
            allocationState: WatchOnlyAccountAllocationState(
                highestAccountIndexByWallet: ["0": 7],
                pendingAccountIndexByRequest: ["0:pending": 7]
            ),
            defaults: defaults
        )
        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "pending",
            defaults: defaults
        ), 7)

        try WatchOnlyAccountStore.restore(
            [],
            allocationState: WatchOnlyAccountAllocationState(
                highestAccountIndexByWallet: ["0": 0],
                pendingAccountIndexByRequest: ["0:pending": 8]
            ),
            defaults: defaults
        )

        let snapshot = try WatchOnlyAccountStore.backupSnapshot(defaults: defaults)
        XCTAssertNil(snapshot.allocationState.pendingAccountIndexByRequest["0:pending"])
        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "pending",
            defaults: defaults
        ), 9)
    }

    func testRestoreBurnsConflictingPendingReservationSlot() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try WatchOnlyAccountStore.restore(
            [],
            allocationState: WatchOnlyAccountAllocationState(
                highestAccountIndexByWallet: ["0": 0],
                pendingAccountIndexByRequest: [
                    "0:first": 1,
                    "0:second": 1,
                ]
            ),
            defaults: defaults
        )

        let snapshot = try WatchOnlyAccountStore.backupSnapshot(defaults: defaults)
        XCTAssertTrue(snapshot.allocationState.pendingAccountIndexByRequest.isEmpty)
        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "next",
            defaults: defaults
        ), 2)
    }

    func testRestoreSanitizesDuplicateAccountOwners() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let xpub = base58CheckEncode(Data(repeating: 1, count: 78))
        let sharedId = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let pendingDuplicateId = makeRecord(
            accountIndex: 1,
            xpub: xpub,
            id: sharedId,
            requestFingerprint: "pending-duplicate-id"
        )
        let activeDuplicateId = makeRecord(
            accountIndex: 2,
            xpub: xpub,
            setupState: .active,
            id: sharedId,
            requestFingerprint: "completed-request"
        )
        let pendingDuplicateSlot = makeRecord(
            accountIndex: 3,
            xpub: xpub,
            requestFingerprint: "pending-duplicate-slot"
        )
        let authorizingDuplicateSlot = makeRecord(
            accountIndex: 3,
            xpub: xpub,
            setupState: .authorizing,
            requestFingerprint: "authorizing-duplicate-slot"
        )
        let pendingDuplicateRequest = makeRecord(
            accountIndex: 4,
            xpub: xpub,
            requestFingerprint: "duplicate-incomplete-request"
        )
        let authorizingDuplicateRequest = makeRecord(
            accountIndex: 5,
            xpub: xpub,
            setupState: .authorizing,
            requestFingerprint: "duplicate-incomplete-request"
        )
        let repeatedCompletedRequest = makeRecord(
            accountIndex: 6,
            xpub: xpub,
            setupState: .active,
            requestFingerprint: "completed-request"
        )

        try WatchOnlyAccountStore.restore(
            [
                pendingDuplicateId,
                activeDuplicateId,
                pendingDuplicateSlot,
                authorizingDuplicateSlot,
                pendingDuplicateRequest,
                authorizingDuplicateRequest,
                repeatedCompletedRequest,
            ],
            allocationState: WatchOnlyAccountAllocationState(
                highestAccountIndexByWallet: ["0": 6],
                pendingAccountIndexByRequest: [
                    "0:pending-duplicate-id": 1,
                    "0:duplicate-incomplete-request": 4,
                ]
            ),
            defaults: defaults
        )

        let restored = try WatchOnlyAccountStore.load(defaults: defaults)
        XCTAssertEqual(
            Set(restored.map(\.id)),
            Set([activeDuplicateId.id, authorizingDuplicateSlot.id, authorizingDuplicateRequest.id, repeatedCompletedRequest.id])
        )
        XCTAssertEqual(restored.map(\.accountIndex), [2, 3, 5, 6])
        let snapshot = try WatchOnlyAccountStore.backupSnapshot(defaults: defaults)
        XCTAssertNil(snapshot.allocationState.pendingAccountIndexByRequest["0:pending-duplicate-id"])
        XCTAssertNil(snapshot.allocationState.pendingAccountIndexByRequest["0:duplicate-incomplete-request"])
        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "pending-duplicate-id",
            defaults: defaults
        ), 7)
    }

    func testRestoreRaisesHighWaterForDiscardedDuplicateAccount() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sharedId = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let xpub = base58CheckEncode(Data(repeating: 1, count: 78))
        let retained = makeRecord(
            accountIndex: 1,
            xpub: xpub,
            setupState: .active,
            id: sharedId,
            requestFingerprint: "retained"
        )
        let discarded = makeRecord(
            accountIndex: 7,
            xpub: xpub,
            setupState: .active,
            id: sharedId,
            requestFingerprint: "discarded"
        )

        try WatchOnlyAccountStore.restore([discarded, retained], defaults: defaults)

        XCTAssertEqual(try WatchOnlyAccountStore.load(defaults: defaults), [retained])
        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "next",
            defaults: defaults
        ), 8)
    }

    func testRestoreRejectsReservationAtDiscardedAccountSlot() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sharedId = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let xpub = base58CheckEncode(Data(repeating: 1, count: 78))
        let retained = makeRecord(accountIndex: 1, xpub: xpub, setupState: .active, id: sharedId)
        let discarded = makeRecord(accountIndex: 7, xpub: xpub, setupState: .active, id: sharedId)

        try WatchOnlyAccountStore.restore(
            [discarded, retained],
            allocationState: WatchOnlyAccountAllocationState(
                highestAccountIndexByWallet: ["0": 7],
                pendingAccountIndexByRequest: ["0:retry": 7]
            ),
            defaults: defaults
        )

        let snapshot = try WatchOnlyAccountStore.backupSnapshot(defaults: defaults)
        XCTAssertNil(snapshot.allocationState.pendingAccountIndexByRequest["0:retry"])
        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "retry",
            defaults: defaults
        ), 8)
    }

    func testRestoreNormalizesTrackingForIncompleteAccounts() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let xpub = base58CheckEncode(Data(repeating: 1, count: 78))
        let pending = makeRecord(
            accountIndex: 1,
            xpub: xpub,
            isTrackingEnabled: true,
            requestFingerprint: "pending"
        )
        let authorizing = makeRecord(
            accountIndex: 2,
            xpub: xpub,
            isTrackingEnabled: false,
            setupState: .authorizing,
            requestFingerprint: "authorizing"
        )
        let disabledActive = makeRecord(
            accountIndex: 3,
            xpub: xpub,
            isTrackingEnabled: false,
            setupState: .active,
            requestFingerprint: "active"
        )

        try WatchOnlyAccountStore.restore([pending, authorizing, disabledActive], defaults: defaults)

        let accounts = try WatchOnlyAccountStore.load(defaults: defaults)
        XCTAssertEqual(accounts.first(where: { $0.id == pending.id })?.isTrackingEnabled, false)
        XCTAssertEqual(accounts.first(where: { $0.id == authorizing.id })?.isTrackingEnabled, true)
        XCTAssertEqual(accounts.first(where: { $0.id == disabledActive.id })?.isTrackingEnabled, false)
    }

    func testRestoreDropsUnusableAccountsAndBurnsTheirIndexes() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let xpub = base58CheckEncode(Data(repeating: 1, count: 78))
        let valid = makeRecord(accountIndex: 1, xpub: xpub, setupState: .active)
        let invalidAddressType = makeRecord(
            accountIndex: 7,
            xpub: xpub,
            addressType: "legacy",
            setupState: .active
        )
        let invalidXpub = makeRecord(accountIndex: 8, xpub: "not-an-xpub", setupState: .authorizing)
        let accountZero = makeRecord(accountIndex: 0, xpub: xpub, setupState: .active)
        let outOfRange = makeRecord(accountIndex: .max, xpub: xpub, setupState: .active)

        try WatchOnlyAccountStore.restore(
            [outOfRange, invalidXpub, accountZero, invalidAddressType, valid],
            allocationState: WatchOnlyAccountAllocationState(
                highestAccountIndexByWallet: ["0": .max],
                pendingAccountIndexByRequest: ["0:out-of-range": .max]
            ),
            defaults: defaults
        )

        XCTAssertEqual(try WatchOnlyAccountStore.load(defaults: defaults), [valid])
        XCTAssertEqual(try WatchOnlyAccountStore.enabledAccounts(for: 0, defaults: defaults), [valid])
        XCTAssertNil(
            try WatchOnlyAccountStore.backupSnapshot(defaults: defaults)
                .allocationState.pendingAccountIndexByRequest["0:out-of-range"]
        )
        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "next",
            defaults: defaults
        ), 9)
    }

    func testRestorePreservesAuthorizingAccountsOverBackupConflicts() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let xpub = base58CheckEncode(Data(repeating: 1, count: 78))
        let authorizingById = makeRecord(
            accountIndex: 1,
            xpub: xpub,
            setupState: .authorizing,
            requestFingerprint: "authorizing-by-id"
        )
        let authorizingByKey = makeRecord(
            accountIndex: 2,
            xpub: xpub,
            setupState: .authorizing,
            requestFingerprint: "authorizing-by-key"
        )
        try WatchOnlyAccountStore.save([authorizingById, authorizingByKey], defaults: defaults)

        let conflictingId = makeRecord(
            accountIndex: 9,
            xpub: xpub,
            setupState: .active,
            id: authorizingById.id,
            requestFingerprint: "backup-id-conflict"
        )
        let conflictingKey = makeRecord(
            accountIndex: authorizingByKey.accountIndex,
            xpub: xpub,
            setupState: .active,
            requestFingerprint: "backup-key-conflict"
        )
        let restored = makeRecord(
            accountIndex: 7,
            xpub: xpub,
            setupState: .active,
            requestFingerprint: "restored"
        )
        try WatchOnlyAccountStore.restore(
            [conflictingId, conflictingKey, restored],
            allocationState: WatchOnlyAccountAllocationState(
                highestAccountIndexByWallet: ["0": 9],
                pendingAccountIndexByRequest: ["0:restored": restored.accountIndex]
            ),
            defaults: defaults
        )

        let accounts = try WatchOnlyAccountStore.load(defaults: defaults)
        XCTAssertEqual(Set(accounts.map(\.id)), Set([authorizingById.id, authorizingByKey.id, restored.id]))
        XCTAssertEqual(accounts.first(where: { $0.id == authorizingById.id }), authorizingById)
        XCTAssertEqual(accounts.first(where: { $0.id == authorizingByKey.id }), authorizingByKey)
        let snapshot = try WatchOnlyAccountStore.backupSnapshot(defaults: defaults)
        XCTAssertEqual(snapshot.allocationState.pendingAccountIndexByRequest["0:authorizing-by-id"], 1)
        XCTAssertEqual(snapshot.allocationState.pendingAccountIndexByRequest["0:authorizing-by-key"], 2)
        XCTAssertNil(snapshot.allocationState.pendingAccountIndexByRequest["0:restored"])

        _ = try WatchOnlyAccountStore.markSetupActive(id: authorizingById.id, defaults: defaults)
        XCTAssertEqual(
            try WatchOnlyAccountStore.load(defaults: defaults).first(where: { $0.id == authorizingById.id })?.setupState,
            .active
        )
    }

    func testRestorePreservesLocalOwnerWhenBackupReusesItsSlot() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let xpub = base58CheckEncode(Data(repeating: 1, count: 78))
        let local = makeRecord(
            accountIndex: 5,
            xpub: xpub,
            setupState: .active,
            requestFingerprint: "local-owner"
        )
        let conflictingBackup = makeRecord(
            accountIndex: 5,
            xpub: xpub,
            setupState: .active,
            requestFingerprint: "restored-owner"
        )
        try WatchOnlyAccountStore.save([local], defaults: defaults)

        try WatchOnlyAccountStore.restore([conflictingBackup], defaults: defaults)

        XCTAssertEqual(try WatchOnlyAccountStore.load(defaults: defaults), [local])
        XCTAssertEqual(try WatchOnlyAccountStore.reconciliationSnapshot(defaults: defaults).managedAccounts, [local])
    }

    func testRestorePrefersDeliveredOwnerOverLocalPendingSlot() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let xpub = base58CheckEncode(Data(repeating: 1, count: 78))
        let localPending = makeRecord(
            accountIndex: 5,
            xpub: xpub,
            isTrackingEnabled: false,
            requestFingerprint: "local-pending"
        )
        let restoredActive = makeRecord(
            accountIndex: 5,
            xpub: xpub,
            setupState: .active,
            requestFingerprint: "restored-active"
        )
        try WatchOnlyAccountStore.save([localPending], defaults: defaults)

        try WatchOnlyAccountStore.restore([restoredActive], defaults: defaults)

        XCTAssertEqual(try WatchOnlyAccountStore.load(defaults: defaults), [restoredActive])
        XCTAssertEqual(try WatchOnlyAccountStore.enabledAccounts(for: 0, defaults: defaults), [restoredActive])
        XCTAssertEqual(try WatchOnlyAccountStore.reconciliationSnapshot(defaults: defaults).managedAccounts, [restoredActive])
    }

    func testRestoreKeepsTrackingEnabledAcrossDeliveredOwnerConflict() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let xpub = base58CheckEncode(Data(repeating: 1, count: 78))
        let localDisabled = makeRecord(
            accountIndex: 5,
            xpub: xpub,
            isTrackingEnabled: false,
            setupState: .active,
            requestFingerprint: "local-active"
        )
        let restoredEnabled = makeRecord(
            accountIndex: 5,
            xpub: xpub,
            setupState: .active,
            requestFingerprint: "restored-active"
        )
        try WatchOnlyAccountStore.save([localDisabled], defaults: defaults)

        try WatchOnlyAccountStore.restore([restoredEnabled], defaults: defaults)

        let account = try XCTUnwrap(try WatchOnlyAccountStore.load(defaults: defaults).first)
        XCTAssertEqual(account.id, localDisabled.id)
        XCTAssertTrue(account.isTrackingEnabled)
        XCTAssertEqual(try WatchOnlyAccountStore.enabledAccounts(for: 0, defaults: defaults), [account])
    }

    func testRestoreProtectsOwnerAwaitingUnloadFromConflictingSlot() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let xpub = base58CheckEncode(Data(repeating: 1, count: 78))
        let local = makeRecord(
            accountIndex: 5,
            xpub: xpub,
            setupState: .active,
            requestFingerprint: "local-owner"
        )
        let conflictingBackup = makeRecord(
            accountIndex: 5,
            xpub: xpub,
            setupState: .active,
            requestFingerprint: "restored-owner"
        )
        try WatchOnlyAccountStore.save([local], defaults: defaults)
        try WatchOnlyAccountStore.restore([], defaults: defaults)

        try WatchOnlyAccountStore.restore([conflictingBackup], defaults: defaults)

        XCTAssertEqual(try WatchOnlyAccountStore.load(defaults: defaults), [local])
        XCTAssertEqual(try WatchOnlyAccountStore.reconciliationSnapshot(defaults: defaults).managedAccounts, [local])
    }

    func testRestoreDoesNotRegressActiveLocalOwnerToIncomplete() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let xpub = base58CheckEncode(Data(repeating: 1, count: 78))
        let local = makeRecord(
            accountIndex: 5,
            xpub: xpub,
            setupState: .active,
            requestFingerprint: "same-owner"
        )
        let incompleteBackup = makeRecord(
            accountIndex: 5,
            xpub: xpub,
            isTrackingEnabled: false,
            requestFingerprint: local.requestFingerprint
        )
        try WatchOnlyAccountStore.save([local], defaults: defaults)

        try WatchOnlyAccountStore.restore([incompleteBackup], defaults: defaults)

        XCTAssertEqual(try WatchOnlyAccountStore.load(defaults: defaults), [local])
    }

    func testRestoreUsesSameCanonicalIncompleteOwnerRegardlessOfInputOrder() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let xpub = base58CheckEncode(Data(repeating: 1, count: 78))
        let lowerIndexId = try XCTUnwrap(UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff"))
        let higherIndexId = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let lowerIndex = makeRecord(
            accountIndex: 3,
            xpub: xpub,
            isTrackingEnabled: false,
            id: lowerIndexId,
            requestFingerprint: "shared-request"
        )
        let higherIndex = makeRecord(
            accountIndex: 4,
            xpub: xpub,
            isTrackingEnabled: false,
            id: higherIndexId,
            requestFingerprint: lowerIndex.requestFingerprint
        )

        try WatchOnlyAccountStore.restore([higherIndex, lowerIndex], defaults: defaults)
        XCTAssertEqual(try WatchOnlyAccountStore.load(defaults: defaults), [lowerIndex])

        try WatchOnlyAccountStore.restore([lowerIndex, higherIndex], defaults: defaults)
        XCTAssertEqual(try WatchOnlyAccountStore.load(defaults: defaults), [lowerIndex])
    }

    func testRestoreDropsPendingReservationThatCollidesWithAuthorizingRequest() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let xpub = base58CheckEncode(Data(repeating: 1, count: 78))
        let authorizing = makeRecord(
            accountIndex: 5,
            xpub: xpub,
            setupState: .authorizing,
            requestFingerprint: "request-a"
        )
        try WatchOnlyAccountStore.restore(
            [authorizing],
            allocationState: WatchOnlyAccountAllocationState(
                highestAccountIndexByWallet: ["0": 5],
                pendingAccountIndexByRequest: ["0:request-a": 5]
            ),
            defaults: defaults
        )

        let conflictingBackupAccount = makeRecord(
            accountIndex: 5,
            xpub: xpub,
            requestFingerprint: "request-b"
        )
        try WatchOnlyAccountStore.restore(
            [conflictingBackupAccount],
            allocationState: WatchOnlyAccountAllocationState(
                highestAccountIndexByWallet: ["0": 5],
                pendingAccountIndexByRequest: ["0:request-b": 5]
            ),
            defaults: defaults
        )

        let snapshot = try WatchOnlyAccountStore.backupSnapshot(defaults: defaults)
        XCTAssertEqual(snapshot.accounts, [authorizing])
        XCTAssertEqual(snapshot.allocationState.pendingAccountIndexByRequest["0:request-a"], 5)
        XCTAssertNil(snapshot.allocationState.pendingAccountIndexByRequest["0:request-b"])
        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "request-b",
            defaults: defaults
        ), 6)
    }

    func testRestoreDropsUnboundPendingReservationBelowLocalHighWaterMark() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "first",
            defaults: defaults
        ), 1)
        try WatchOnlyAccountStore.completeAllocation(walletIndex: 0, requestFingerprint: "first", defaults: defaults)
        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "second",
            defaults: defaults
        ), 2)
        try WatchOnlyAccountStore.completeAllocation(walletIndex: 0, requestFingerprint: "second", defaults: defaults)

        try WatchOnlyAccountStore.restore(
            [],
            allocationState: WatchOnlyAccountAllocationState(
                highestAccountIndexByWallet: ["0": 1],
                pendingAccountIndexByRequest: ["0:restored-request": 1]
            ),
            defaults: defaults
        )

        let snapshot = try WatchOnlyAccountStore.backupSnapshot(defaults: defaults)
        XCTAssertNil(snapshot.allocationState.pendingAccountIndexByRequest["0:restored-request"])
        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "restored-request",
            defaults: defaults
        ), 3)
    }

    func testRestoreDropsPendingReservationForAccountAwaitingUnload() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let accountAwaitingUnload = makeRecord(
            accountIndex: 5,
            xpub: base58CheckEncode(Data(repeating: 1, count: 78)),
            setupState: .active,
            requestFingerprint: "current-request"
        )
        try WatchOnlyAccountStore.save([accountAwaitingUnload], defaults: defaults)

        try WatchOnlyAccountStore.restore(
            [],
            allocationState: WatchOnlyAccountAllocationState(
                highestAccountIndexByWallet: ["0": 5],
                pendingAccountIndexByRequest: ["0:restored-request": 5]
            ),
            defaults: defaults
        )

        let snapshot = try WatchOnlyAccountStore.backupSnapshot(defaults: defaults)
        XCTAssertNil(snapshot.allocationState.pendingAccountIndexByRequest["0:restored-request"])
        XCTAssertEqual(
            try WatchOnlyAccountStore.reconciliationSnapshot(defaults: defaults).managedAccounts,
            [accountAwaitingUnload]
        )
        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "restored-request",
            defaults: defaults
        ), 6)
    }

    func testCorruptedStateFailsClosedWithoutResettingAllocator() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let corruptedData = Data("not-json".utf8)
        defaults.set(corruptedData, forKey: WatchOnlyAccountStore.dataKey)

        XCTAssertThrowsError(try WatchOnlyAccountStore.load(defaults: defaults))
        XCTAssertThrowsError(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "request",
            defaults: defaults
        ))
        XCTAssertEqual(defaults.data(forKey: WatchOnlyAccountStore.dataKey), corruptedData)
    }

    func testRestoreRepairsCorruptedLocalStateFromValidBackup() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: WatchOnlyAccountStore.dataKey)
        let restored = makeRecord(
            accountIndex: 4,
            xpub: base58CheckEncode(Data(repeating: 1, count: 78)),
            setupState: .active
        )

        try WatchOnlyAccountStore.restore(
            [restored],
            allocationState: WatchOnlyAccountAllocationState(
                highestAccountIndexByWallet: ["0": 6],
                pendingAccountIndexByRequest: ["0:pending": 6]
            ),
            defaults: defaults
        )

        XCTAssertEqual(try WatchOnlyAccountStore.load(defaults: defaults), [restored])
        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "pending",
            defaults: defaults
        ), 6)
    }

    func testReconciliationClearsPendingUnloadsOnlyForCurrentWallet() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let xpub = base58CheckEncode(Data(repeating: 1, count: 78))
        let walletZero = makeRecord(accountIndex: 1, xpub: xpub, walletIndex: 0, setupState: .active)
        let walletOne = makeRecord(accountIndex: 1, xpub: xpub, walletIndex: 1, setupState: .active)
        try WatchOnlyAccountStore.save([walletZero, walletOne], defaults: defaults)
        try WatchOnlyAccountStore.restore([], defaults: defaults)

        try WatchOnlyAccountStore.finishReconciliation(walletIndex: 0, defaults: defaults)

        XCTAssertEqual(try WatchOnlyAccountStore.reconciliationSnapshot(defaults: defaults).managedAccounts, [walletOne])

        try WatchOnlyAccountStore.finishReconciliation(walletIndex: 1, defaults: defaults)
        XCTAssertTrue(try WatchOnlyAccountStore.reconciliationSnapshot(defaults: defaults).managedAccounts.isEmpty)
    }

    func testStartupTrackingIncludesEnabledActiveAndAuthorizingAccountsForCurrentWallet() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let xpub = base58CheckEncode(Data(repeating: 1, count: 78))
        try WatchOnlyAccountStore.save(
            [
                makeRecord(accountIndex: 1, xpub: xpub, setupState: .active),
                makeRecord(accountIndex: 2, xpub: xpub, isTrackingEnabled: false, setupState: .active),
                makeRecord(accountIndex: 3, xpub: xpub, walletIndex: 1, setupState: .active),
                makeRecord(accountIndex: 4, xpub: xpub, setupState: .pendingDelivery),
                makeRecord(accountIndex: 5, xpub: xpub, setupState: .authorizing),
            ],
            defaults: defaults
        )

        XCTAssertEqual(try WatchOnlyAccountStore.enabledAccounts(for: 0, defaults: defaults).map(\.accountIndex), [1, 5])
    }

    @MainActor
    func testEachSetupGetsANewAccountAndRetryReusesPendingAccount() async throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let node = FakeWatchOnlyAccountNode()
        let manager = WatchOnlyAccountManager(defaults: defaults, node: node)

        let first = try await manager.prepareUnsignedClaim(authUrl: "pubkyauth:///?secret=one", name: "Store one")
        let retry = try await manager.prepareUnsignedClaim(authUrl: "pubkyauth:///?secret=one", name: "Changed")
        try await activateSetupAuthorization(manager: manager, id: first.0.id)
        let repeatedAfterCompletion = try await manager.prepareUnsignedClaim(
            authUrl: "pubkyauth:///?secret=one",
            name: "Store one again"
        )
        let second = try await manager.prepareUnsignedClaim(authUrl: "pubkyauth:///?secret=two", name: "Store two")

        XCTAssertEqual(first.0.accountIndex, 1)
        XCTAssertEqual(retry.0.id, first.0.id)
        XCTAssertEqual(repeatedAfterCompletion.0.accountIndex, 2)
        XCTAssertEqual(second.0.accountIndex, 3)
        XCTAssertEqual(node.exportedAccountIndexes, [1, 2, 3])
        XCTAssertEqual(try WatchOnlyAccountStore.load(defaults: defaults).count, 3)
    }

    @MainActor
    func testEquivalentAuthUrlsReuseTheSamePendingAccount() async throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let node = FakeWatchOnlyAccountNode()
        let manager = WatchOnlyAccountManager(defaults: defaults, node: node)
        let first = try await manager.prepareUnsignedClaim(
            authUrl: "pubkyauth://signin?caps=/pub/paykit/v0/bitkit/server/:rw&secret=same&relay=https%3A%2F%2Frelay.test&x-bitkit-claim=watch-only-account-v1",
            name: "First"
        )
        let reordered = try await manager.prepareUnsignedClaim(
            authUrl: "pubkyauth://signin?relay=https://relay.test&x-bitkit-claim=watch-only-account-v1&secret=s%61me&caps=/pub/paykit/v0/bitkit/server/:rw",
            name: "Renamed"
        )
        let differentRelay = try await manager.prepareUnsignedClaim(
            authUrl: "pubkyauth://signin?relay=https://other-relay.test&x-bitkit-claim=watch-only-account-v1&secret=same&caps=/pub/paykit/v0/bitkit/server/:rw",
            name: "Other relay"
        )

        XCTAssertEqual(reordered.0.id, first.0.id)
        XCTAssertEqual(reordered.0.accountIndex, first.0.accountIndex)
        XCTAssertEqual(differentRelay.0.accountIndex, 2)
        XCTAssertEqual(node.exportedAccountIndexes, [1, 2])
    }

    @MainActor
    func testConcurrentPreparationForTheSameRequestCreatesOneAccount() async throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let node = FakeWatchOnlyAccountNode()
        node.creationDelayNanoseconds = 20_000_000
        let manager = WatchOnlyAccountManager(defaults: defaults, node: node)

        async let first = manager.prepareUnsignedClaim(authUrl: "pubkyauth://signin?secret=same", name: "Account")
        async let second = manager.prepareUnsignedClaim(authUrl: "pubkyauth://signin?secret=same", name: "Account")
        let prepared = try await (first, second)

        XCTAssertEqual(prepared.0.0.id, prepared.1.0.id)
        XCTAssertEqual(node.exportedAccountIndexes, [1])
        XCTAssertEqual(try WatchOnlyAccountStore.load(defaults: defaults).count, 1)
    }

    func testActivationAndReservationCompletionPersistAtomically() throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let accountIndex = try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "request",
            defaults: defaults
        )
        let record = makeRecord(
            accountIndex: accountIndex,
            xpub: base58CheckEncode(Data(repeating: 1, count: 78)),
            isTrackingEnabled: false
        )
        try WatchOnlyAccountStore.save([record], defaults: defaults)

        let activeAccounts = try WatchOnlyAccountStore.markSetupActive(id: record.id, defaults: defaults)
        let snapshot = try WatchOnlyAccountStore.backupSnapshot(defaults: defaults)

        XCTAssertEqual(activeAccounts.count, 1)
        XCTAssertEqual(activeAccounts.first?.setupState, .active)
        XCTAssertTrue(try XCTUnwrap(activeAccounts.first).isTrackingEnabled)
        XCTAssertTrue(snapshot.allocationState.pendingAccountIndexByRequest.isEmpty)
        XCTAssertEqual(try WatchOnlyAccountStore.reserveAccountIndex(
            walletIndex: 0,
            requestFingerprint: "request",
            defaults: defaults
        ), 2)
    }

    @MainActor
    func testFailedCreationReservesAndReusesAccountIndex() async throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let node = FakeWatchOnlyAccountNode()
        node.failNextCreation = true
        let manager = WatchOnlyAccountManager(defaults: defaults, node: node)

        await XCTAssertThrowsErrorAsync {
            try await manager.prepareUnsignedClaim(authUrl: "pubkyauth:///?secret=retry", name: "Retry")
        }
        let retry = try await manager.prepareUnsignedClaim(authUrl: "pubkyauth:///?secret=retry", name: "Retry")
        let next = try await manager.prepareUnsignedClaim(authUrl: "pubkyauth:///?secret=next", name: "Next")

        XCTAssertEqual(retry.0.accountIndex, 1)
        XCTAssertEqual(next.0.accountIndex, 2)
        XCTAssertEqual(node.exportedAccountIndexes, [1, 1, 2])
    }

    @MainActor
    func testRenameTrackingAndActiveStatePersist() async throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let node = FakeWatchOnlyAccountNode()
        let manager = WatchOnlyAccountManager(defaults: defaults, node: node)
        let prepared = try await manager.prepareUnsignedClaim(
            authUrl: "pubkyauth:///?secret=state",
            name: "Original"
        )

        try await manager.rename(id: prepared.0.id, name: "Creator shop")
        XCTAssertFalse(try XCTUnwrap(try WatchOnlyAccountStore.load(defaults: defaults).first).isTrackingEnabled)
        try await activateSetupAuthorization(manager: manager, id: prepared.0.id)
        try await manager.setTrackingEnabled(id: prepared.0.id, enabled: false)

        let stored = try XCTUnwrap(try WatchOnlyAccountStore.load(defaults: defaults).first)
        XCTAssertEqual(stored.name, "Creator shop")
        XCTAssertFalse(stored.isTrackingEnabled)
        XCTAssertEqual(stored.setupState, .active)
        XCTAssertEqual(node.trackingChanges, [.init(accountIndex: 1, enabled: true), .init(accountIndex: 1, enabled: false)])

        let reloadedManager = WatchOnlyAccountManager(defaults: defaults, node: node)
        try await reloadedManager.setTrackingEnabled(id: stored.id, enabled: true)
        XCTAssertTrue(try XCTUnwrap(try WatchOnlyAccountStore.load(defaults: defaults).first).isTrackingEnabled)
        XCTAssertEqual(
            node.trackingChanges,
            [
                .init(accountIndex: 1, enabled: true),
                .init(accountIndex: 1, enabled: false),
                .init(accountIndex: 1, enabled: true),
            ]
        )
    }

    @MainActor
    func testAuthorizationAndActivationFailWhenPreparedAccountIsMissing() async throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = WatchOnlyAccountManager(defaults: defaults, node: FakeWatchOnlyAccountNode())
        let missingId = UUID()

        for operation in [
            { (attempt: WatchOnlyAccountAuthorizationAttempt) in try await manager.beginSetupAuthorization(attempt: attempt) },
            { (attempt: WatchOnlyAccountAuthorizationAttempt) in try await manager.markSetupActive(attempt: attempt) },
        ] {
            let attempt = try manager.acquireSetupAuthorizationAttempt(id: missingId)
            do {
                try await operation(attempt)
                XCTFail("Expected a missing authorization account error")
            } catch {
                XCTAssertEqual(error as? WatchOnlyAccountError, .authorizationAccountMissing)
            }
            manager.finishSetupAuthorizationAttempt(attempt)
        }
    }

    @MainActor
    func testFailedAuthorizationUnloadKeepsPersistedAuthorizingState() async throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let node = FakeWatchOnlyAccountNode()
        let manager = WatchOnlyAccountManager(defaults: defaults, node: node)
        let prepared = try await manager.prepareUnsignedClaim(
            authUrl: "pubkyauth:///?secret=failed-unload",
            name: "Failed unload"
        )
        let authorizationAttempt = try manager.acquireSetupAuthorizationAttempt(id: prepared.0.id)
        defer { manager.finishSetupAuthorizationAttempt(authorizationAttempt) }
        try await manager.beginSetupAuthorization(attempt: authorizationAttempt)
        node.failNextTrackingDisable = true

        await XCTAssertThrowsErrorAsync {
            try await manager.cancelSetupAuthorization(attempt: authorizationAttempt)
        }

        let stored = try XCTUnwrap(try WatchOnlyAccountStore.load(defaults: defaults).first)
        XCTAssertEqual(stored.setupState, .authorizing)
        XCTAssertTrue(stored.isTrackingEnabled)
        XCTAssertEqual(node.trackedAccountIndexes, [prepared.0.accountIndex])
    }

    @MainActor
    func testAuthorizationAttemptRemainsExclusiveAfterCleanupUntilOwnerFinishes() async throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = WatchOnlyAccountManager(defaults: defaults, node: FakeWatchOnlyAccountNode())
        let prepared = try await manager.prepareUnsignedClaim(
            authUrl: "pubkyauth:///?secret=exclusive-cleanup",
            name: "Exclusive cleanup"
        )
        let firstAttempt = try manager.acquireSetupAuthorizationAttempt(id: prepared.0.id)
        try await manager.beginSetupAuthorization(attempt: firstAttempt)
        try await manager.cancelSetupAuthorization(attempt: firstAttempt)

        do {
            _ = try manager.acquireSetupAuthorizationAttempt(id: prepared.0.id)
            XCTFail("Expected the original authorization owner to remain exclusive")
        } catch {
            XCTAssertEqual(error as? WatchOnlyAccountError, .authorizationInProgress)
        }

        manager.finishSetupAuthorizationAttempt(firstAttempt)
        let retryAttempt = try manager.acquireSetupAuthorizationAttempt(id: prepared.0.id)
        defer { manager.finishSetupAuthorizationAttempt(retryAttempt) }
        try await manager.beginSetupAuthorization(attempt: retryAttempt)
        manager.finishSetupAuthorizationAttempt(firstAttempt)

        do {
            _ = try manager.acquireSetupAuthorizationAttempt(id: prepared.0.id)
            XCTFail("Expected a stale finish not to release the retry")
        } catch {
            XCTAssertEqual(error as? WatchOnlyAccountError, .authorizationInProgress)
        }
        do {
            try await manager.cancelSetupAuthorization(attempt: firstAttempt)
            XCTFail("Expected stale cleanup to be rejected")
        } catch {
            XCTAssertEqual(error as? WatchOnlyAccountError, .authorizationInProgress)
        }

        let stored = try XCTUnwrap(try WatchOnlyAccountStore.load(defaults: defaults).first)
        XCTAssertEqual(stored.setupState, .authorizing)
        XCTAssertTrue(stored.isTrackingEnabled)
    }

    @MainActor
    func testActivationPersistsAfterCallerCancellationWhileWaitingForLifecycleLock() async throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let contentionProbe = LifecycleQueueProbe()
        let coordinator = WatchOnlyAccountLifecycleCoordinator {
            contentionProbe.markQueued()
        }
        let lockGate = LifecycleTestGate()
        let lockProbe = LifecycleLockProbe()
        let manager = WatchOnlyAccountManager(
            defaults: defaults,
            lifecycleCoordinator: coordinator,
            node: FakeWatchOnlyAccountNode()
        )
        let prepared = try await manager.prepareUnsignedClaim(
            authUrl: "pubkyauth:///?secret=cancelled-activation",
            name: "Cancelled activation"
        )
        let authorizationAttempt = try manager.acquireSetupAuthorizationAttempt(id: prepared.0.id)
        defer { manager.finishSetupAuthorizationAttempt(authorizationAttempt) }
        try await manager.beginSetupAuthorization(attempt: authorizationAttempt)
        let lockHolder = Task {
            try await coordinator.withLock {
                await lockProbe.markEntered()
                await lockGate.wait()
            }
        }
        try await waitUntil { await lockProbe.hasEntered }

        let activation = Task { @MainActor in
            try await manager.markSetupActive(attempt: authorizationAttempt)
        }
        try await waitUntil { contentionProbe.queuedCount >= 1 }
        activation.cancel()
        await lockGate.open()
        try await lockHolder.value
        try await activation.value

        let stored = try XCTUnwrap(try WatchOnlyAccountStore.load(defaults: defaults).first)
        XCTAssertEqual(stored.setupState, .active)
        XCTAssertTrue(stored.isTrackingEnabled)
    }

    @MainActor
    func testAuthorizationSerializesReconciliationUntilTrackingStateIsPersisted() async throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let contentionProbe = LifecycleQueueProbe()
        let coordinator = WatchOnlyAccountLifecycleCoordinator {
            contentionProbe.markQueued()
        }
        let node = FakeWatchOnlyAccountNode()
        let trackingGate = LifecycleTestGate()
        node.trackingGate = trackingGate
        let manager = WatchOnlyAccountManager(defaults: defaults, lifecycleCoordinator: coordinator, node: node)
        let prepared = try await manager.prepareUnsignedClaim(
            authUrl: "pubkyauth:///?secret=serialized",
            name: "Serialized"
        )

        let authorizationAttempt = try manager.acquireSetupAuthorizationAttempt(id: prepared.0.id)
        defer { manager.finishSetupAuthorizationAttempt(authorizationAttempt) }
        let authorization = Task { @MainActor in
            try await manager.beginSetupAuthorization(attempt: authorizationAttempt)
        }
        try await waitUntil { !node.trackingChanges.isEmpty }
        let reconciliation = Task { @MainActor in
            try await manager.reconcileTracking()
        }

        try await waitUntil { contentionProbe.queuedCount >= 1 }
        XCTAssertTrue(node.reconciliationSnapshots.isEmpty)
        XCTAssertEqual(node.trackedAccountIndexes, [prepared.0.accountIndex])

        await trackingGate.open()
        try await authorization.value
        try await reconciliation.value

        XCTAssertEqual(node.reconciliationSnapshots.count, 1)
        XCTAssertEqual(node.reconciliationSnapshots.first?.first?.setupState, .authorizing)
        XCTAssertEqual(node.reconciliationSnapshots.first?.first?.isTrackingEnabled, true)
        XCTAssertEqual(node.trackedAccountIndexes, [prepared.0.accountIndex])
        let stored = try XCTUnwrap(try WatchOnlyAccountStore.load(defaults: defaults).first)
        XCTAssertEqual(stored.setupState, .authorizing)
        XCTAssertTrue(stored.isTrackingEnabled)
    }

    @MainActor
    func testCancelledLifecycleWaiterDoesNotEnterCriticalSection() async throws {
        let contentionProbe = LifecycleQueueProbe()
        let coordinator = WatchOnlyAccountLifecycleCoordinator {
            contentionProbe.markQueued()
        }
        let holderGate = LifecycleTestGate()
        let holderProbe = LifecycleLockProbe()
        let waiterProbe = LifecycleLockProbe()
        let followingWaiterProbe = LifecycleLockProbe()

        let holder = Task {
            try await coordinator.withLock {
                await holderProbe.markEntered()
                await holderGate.wait()
            }
        }
        try await waitUntil { await holderProbe.hasEntered }

        let waiter = Task {
            try await coordinator.withLock {
                await waiterProbe.markEntered()
            }
        }
        try await waitUntil { contentionProbe.queuedCount >= 1 }
        waiter.cancel()

        let followingWaiter = Task {
            try await coordinator.withLock {
                await followingWaiterProbe.markEntered()
            }
        }
        try await waitUntil { contentionProbe.queuedCount >= 2 }

        await holderGate.open()
        try await holder.value
        do {
            try await waiter.value
            XCTFail("Expected the cancelled lifecycle waiter to throw")
        } catch is CancellationError {}
        try await followingWaiter.value

        let cancelledWaiterDidEnter = await waiterProbe.hasEntered
        let followingWaiterDidEnter = await followingWaiterProbe.hasEntered
        XCTAssertFalse(cancelledWaiterDidEnter)
        XCTAssertTrue(followingWaiterDidEnter)
    }

    @MainActor
    func testRestorePreservesInFlightAuthorization() async throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let contentionProbe = LifecycleQueueProbe()
        let coordinator = WatchOnlyAccountLifecycleCoordinator {
            contentionProbe.markQueued()
        }
        let node = FakeWatchOnlyAccountNode()
        let trackingGate = LifecycleTestGate()
        node.trackingGate = trackingGate
        let manager = WatchOnlyAccountManager(defaults: defaults, lifecycleCoordinator: coordinator, node: node)
        let prepared = try await manager.prepareUnsignedClaim(
            authUrl: "pubkyauth:///?secret=restore-race",
            name: "Original"
        )
        let restored = makeRecord(
            accountIndex: 8,
            xpub: base58CheckEncode(Data(repeating: 8, count: 78)),
            setupState: .active
        )

        let authorizationAttempt = try manager.acquireSetupAuthorizationAttempt(id: prepared.0.id)
        defer { manager.finishSetupAuthorizationAttempt(authorizationAttempt) }
        let authorization = Task { @MainActor in
            try await manager.beginSetupAuthorization(attempt: authorizationAttempt)
        }
        try await waitUntil { !node.trackingChanges.isEmpty }
        let restore = Task { @MainActor in
            try await manager.restore([restored], allocationState: nil)
        }

        try await waitUntil { contentionProbe.queuedCount >= 1 }
        XCTAssertEqual(try WatchOnlyAccountStore.load(defaults: defaults).first?.id, prepared.0.id)

        await trackingGate.open()
        try await authorization.value
        try await restore.value

        let accounts = try WatchOnlyAccountStore.load(defaults: defaults)
        XCTAssertEqual(Set(accounts.map(\.id)), Set([prepared.0.id, restored.id]))
        let authorizingAccount = try XCTUnwrap(accounts.first(where: { $0.id == prepared.0.id }))
        XCTAssertEqual(authorizingAccount.setupState, .authorizing)
        XCTAssertTrue(authorizingAccount.isTrackingEnabled)
        XCTAssertEqual(manager.accounts, accounts)

        try await manager.markSetupActive(attempt: authorizationAttempt)
        XCTAssertEqual(manager.accounts.first(where: { $0.id == prepared.0.id })?.setupState, .active)
    }

    @MainActor
    func testRestoreUnloadsAccountsMissingFromBackup() async throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let node = FakeWatchOnlyAccountNode()
        let manager = WatchOnlyAccountManager(defaults: defaults, node: node)
        let prepared = try await manager.prepareUnsignedClaim(
            authUrl: "pubkyauth:///?secret=removed-by-restore",
            name: "Original"
        )
        try await activateSetupAuthorization(manager: manager, id: prepared.0.id)
        let restored = makeRecord(
            accountIndex: 8,
            xpub: base58CheckEncode(Data(repeating: 8, count: 78)),
            setupState: .active
        )

        try await manager.restore([restored], allocationState: nil)
        try await manager.reconcileTracking()

        XCTAssertEqual(node.trackedAccountIndexes, [restored.accountIndex])
        XCTAssertEqual(node.reconciliationManagedSnapshots.count, 1)
        XCTAssertEqual(Set(node.reconciliationManagedSnapshots[0].map(\.accountIndex)), [prepared.0.accountIndex, restored.accountIndex])
        XCTAssertEqual(try WatchOnlyAccountStore.reconciliationSnapshot(defaults: defaults).managedAccounts, [restored])
    }

    @MainActor
    func testFailedRestoreReconciliationRetainsRemovedAccountsForRetry() async throws {
        let suiteName = "WatchOnlyAccountServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let node = FakeWatchOnlyAccountNode()
        let manager = WatchOnlyAccountManager(defaults: defaults, node: node)
        let prepared = try await manager.prepareUnsignedClaim(
            authUrl: "pubkyauth:///?secret=failed-restore-reconciliation",
            name: "Original"
        )
        try await activateSetupAuthorization(manager: manager, id: prepared.0.id)
        let restored = makeRecord(
            accountIndex: 8,
            xpub: base58CheckEncode(Data(repeating: 8, count: 78)),
            setupState: .active
        )
        try await manager.restore([restored], allocationState: nil)
        node.failNextReconciliationAfterRemovals = true

        await XCTAssertThrowsErrorAsync {
            try await manager.reconcileTracking()
        }

        XCTAssertTrue(node.trackedAccountIndexes.isEmpty)
        XCTAssertEqual(
            try Set(WatchOnlyAccountStore.reconciliationSnapshot(defaults: defaults).managedAccounts.map(\.accountIndex)),
            [prepared.0.accountIndex, restored.accountIndex]
        )

        try await manager.reconcileTracking()

        XCTAssertEqual(node.trackedAccountIndexes, [restored.accountIndex])
        XCTAssertEqual(try WatchOnlyAccountStore.reconciliationSnapshot(defaults: defaults).managedAccounts, [restored])
    }

    @MainActor
    private func activateSetupAuthorization(manager: WatchOnlyAccountManager, id: UUID) async throws {
        let attempt = try manager.acquireSetupAuthorizationAttempt(id: id)
        defer { manager.finishSetupAuthorizationAttempt(attempt) }
        try await manager.beginSetupAuthorization(attempt: attempt)
        try await manager.markSetupActive(attempt: attempt)
    }

    private func makeRecord(
        accountIndex: UInt32,
        xpub: String,
        walletIndex: Int = 0,
        addressType: String = LDKNode.AddressType.nativeSegwit.stringValue,
        isTrackingEnabled: Bool = true,
        setupState: WatchOnlyAccountSetupState = .pendingDelivery,
        id: UUID = UUID(),
        requestFingerprint: String = "request"
    ) -> WatchOnlyAccountRecord {
        WatchOnlyAccountRecord(
            id: id,
            walletIndex: walletIndex,
            accountIndex: accountIndex,
            addressType: addressType,
            xpub: xpub,
            requestFingerprint: requestFingerprint,
            createdAt: 1000,
            name: "Test",
            isTrackingEnabled: isTrackingEnabled,
            setupState: setupState
        )
    }

    private func base58CheckEncode(_ payload: Data) -> String {
        Base58.base58CheckEncode([UInt8](payload))
    }
}

private struct TrackingChange: Equatable {
    let accountIndex: UInt32
    let enabled: Bool
}

private enum FakeNodeError: Error {
    case creationFailed
    case reconciliationFailed
    case trackingFailed
}

private final class FakeWatchOnlyAccountNode: WatchOnlyAccountNodeHandling {
    var currentWalletIndex = 0
    var failNextCreation = false
    var failNextReconciliationAfterRemovals = false
    var failNextTrackingDisable = false
    var creationDelayNanoseconds: UInt64 = 0
    var trackingGate: LifecycleTestGate?
    private(set) var exportedAccountIndexes: [UInt32] = []
    private(set) var trackingChanges: [TrackingChange] = []
    private(set) var reconciliationSnapshots: [[WatchOnlyAccountRecord]] = []
    private(set) var reconciliationManagedSnapshots: [[WatchOnlyAccountRecord]] = []
    private(set) var trackedAccountIndexes: Set<UInt32> = []

    func exportWatchOnlyAccountXpub(accountIndex: UInt32, addressType _: LDKNode.AddressType) async throws -> String {
        exportedAccountIndexes.append(accountIndex)
        if creationDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: creationDelayNanoseconds)
        }
        if failNextCreation {
            failNextCreation = false
            throw FakeNodeError.creationFailed
        }
        let rawXpub = Data((0 ..< WatchOnlyAccountClaimCodec.serializedXpubLength).map { UInt8(($0 + Int(accountIndex)) % 255 + 1) })
        return base58CheckEncode(rawXpub)
    }

    func setWatchOnlyAccountTracking(
        accountIndex: UInt32,
        addressType _: LDKNode.AddressType,
        xpub _: String,
        enabled: Bool
    ) async throws {
        trackingChanges.append(TrackingChange(accountIndex: accountIndex, enabled: enabled))
        if !enabled, failNextTrackingDisable {
            failNextTrackingDisable = false
            throw FakeNodeError.trackingFailed
        }
        if enabled {
            trackedAccountIndexes.insert(accountIndex)
        } else {
            trackedAccountIndexes.remove(accountIndex)
        }
        if let trackingGate {
            await trackingGate.wait()
        }
    }

    func reconcileWatchOnlyAccountTracking(
        records: [WatchOnlyAccountRecord],
        managedRecords: [WatchOnlyAccountRecord]
    ) async throws {
        reconciliationSnapshots.append(records)
        reconciliationManagedSnapshots.append(managedRecords)
        let walletRecords = records.filter { $0.walletIndex == currentWalletIndex }
        let managedAccountIndexes = Set(managedRecords.filter { $0.walletIndex == currentWalletIndex }.map(\.accountIndex))
        let desiredAccountIndexes = Set(walletRecords.filter {
            ($0.setupState == .active || $0.setupState == .authorizing) && $0.isTrackingEnabled
        }.map(\.accountIndex))
        trackedAccountIndexes.subtract(managedAccountIndexes.subtracting(desiredAccountIndexes))
        if failNextReconciliationAfterRemovals {
            failNextReconciliationAfterRemovals = false
            throw FakeNodeError.reconciliationFailed
        }
        trackedAccountIndexes.formUnion(desiredAccountIndexes)
    }

    private func base58CheckEncode(_ payload: Data) -> String {
        Base58.base58CheckEncode([UInt8](payload))
    }
}

private final class LifecycleQueueProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var queuedCount: Int {
        lock.withLock { count }
    }

    func markQueued() {
        lock.withLock { count += 1 }
    }
}

private actor LifecycleLockProbe {
    private(set) var hasAttempted = false
    private(set) var hasEntered = false

    func markAttempted() {
        hasAttempted = true
    }

    func markEntered() {
        hasEntered = true
    }
}

private actor LifecycleTestGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

private enum LifecycleTestError: Error {
    case timedOut
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @MainActor () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while await !condition() {
        guard clock.now < deadline else { throw LifecycleTestError.timedOut }
        await Task.yield()
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
