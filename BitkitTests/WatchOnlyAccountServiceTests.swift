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
        try manager.markSetupActive(id: first.0.id)
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

        try manager.rename(id: prepared.0.id, name: "Creator shop")
        XCTAssertFalse(try XCTUnwrap(try WatchOnlyAccountStore.load(defaults: defaults).first).isTrackingEnabled)
        try await manager.beginSetupAuthorization(id: prepared.0.id)
        try manager.markSetupActive(id: prepared.0.id)
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

    private func makeRecord(
        accountIndex: UInt32,
        xpub: String,
        walletIndex: Int = 0,
        isTrackingEnabled: Bool = true,
        setupState: WatchOnlyAccountSetupState = .pendingDelivery
    ) -> WatchOnlyAccountRecord {
        WatchOnlyAccountRecord(
            id: UUID(),
            walletIndex: walletIndex,
            accountIndex: accountIndex,
            addressType: LDKNode.AddressType.nativeSegwit.stringValue,
            xpub: xpub,
            requestFingerprint: "request",
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
}

private final class FakeWatchOnlyAccountNode: WatchOnlyAccountNodeHandling {
    var currentWalletIndex = 0
    var failNextCreation = false
    var creationDelayNanoseconds: UInt64 = 0
    private(set) var exportedAccountIndexes: [UInt32] = []
    private(set) var trackingChanges: [TrackingChange] = []

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
    }

    private func base58CheckEncode(_ payload: Data) -> String {
        Base58.base58CheckEncode([UInt8](payload))
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
