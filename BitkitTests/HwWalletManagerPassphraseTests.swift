@testable import Bitkit
import BitkitCore
import XCTest

/// Covers the identity-aware session operations on `HwWalletManager`, adapting the passphrase cases
/// in bitkit-android's `HwWalletRepoTest`. The device is a fake session, so the rules that stand
/// between a mistyped passphrase and a signature from the wrong seed are exercised without hardware.
@MainActor
final class HwWalletManagerPassphraseTests: XCTestCase {
    // MARK: - Fake session

    private final class MockHwDeviceSession: HwDeviceSessioning {
        var storedDevices: [TrezorKnownDevice] = []
        var connectedDeviceId: String?
        var connectedWalletId: String?
        var connectedFeatures: TrezorFeatures?

        /// Wallet id the next `connectWithWalletMode` resolves to, per mode. A hidden open that is
        /// not listed here resolves to `openedWalletIdOnHidden`, standing in for the different wallet
        /// a wrong passphrase silently derives.
        var openedWalletIdOnHidden: String?
        var openedWalletIdOnStandard: String?
        /// An entry the device writes when a hidden open reads a wallet Bitkit has never seen,
        /// mirroring how reading accounts persists the wallet before anything can reject it.
        var writesEntryOnHiddenOpen: TrezorKnownDevice?

        var ensureConnectedError: Error?
        var connectWithWalletModeError: Error?
        var blocksStaleDisconnect = false
        var onStaleDisconnect: (() -> Void)?
        private var staleDisconnectContinuation: CheckedContinuation<Void, Never>?

        private(set) var ensureCalls: [String] = []
        private(set) var openCalls: [(deviceId: String, mode: TrezorWalletMode, passphrase: String)] = []
        private(set) var staleDisconnects: [String] = []
        private(set) var forgottenWalletIds: [String] = []
        private(set) var warmUpCalls: [String] = []

        func ensureConnected(deviceId: String) async throws {
            ensureCalls.append(deviceId)
            if let ensureConnectedError { throw ensureConnectedError }
        }

        @discardableResult
        func connectWithWalletMode(
            deviceId: String,
            mode: TrezorWalletMode,
            passphrase: String
        ) async throws -> TrezorFeatures {
            openCalls.append((deviceId, mode, passphrase))
            if let connectWithWalletModeError { throw connectWithWalletModeError }
            connectedDeviceId = deviceId
            switch mode {
            case .standard:
                connectedWalletId = openedWalletIdOnStandard
            case .passphraseHost, .passphraseDevice:
                connectedWalletId = openedWalletIdOnHidden
                if let entry = writesEntryOnHiddenOpen {
                    storedDevices.append(entry)
                    writesEntryOnHiddenOpen = nil
                }
            }
            return connectedFeatures ?? makeFeatures()
        }

        var forgottenPendingNames: [PendingHwWalletName?] = []

        func disconnectStaleSession(deviceId: String) async {
            staleDisconnects.append(deviceId)
            onStaleDisconnect?()
            if blocksStaleDisconnect {
                await withCheckedContinuation { staleDisconnectContinuation = $0 }
            }
        }

        func finishStaleDisconnect() {
            blocksStaleDisconnect = false
            staleDisconnectContinuation?.resume()
            staleDisconnectContinuation = nil
        }

        func isKnownBluetoothDevice(deviceId _: String) -> Bool {
            true
        }

        func warmUpConnection(deviceId: String) {
            warmUpCalls.append(deviceId)
        }

        func forgetWallet(walletId: String, pendingName: PendingHwWalletName?) async {
            forgottenWalletIds.append(walletId)
            forgottenPendingNames.append(pendingName)
            storedDevices.removeAll { $0.resolvedWalletId == walletId }
            if connectedWalletId == walletId { connectedWalletId = nil }
        }
    }

    private final class NoopWatcher: OnChainWatcherServicing, @unchecked Sendable {
        func startWatcher(params _: WatcherParams, listener _: EventListener) async throws {}
        func stopWatcher(watcherId _: String) throws {}
        func stopAllWatchers() {}
    }

    private var session = MockHwDeviceSession()
    private var deletedWalletIds: [String] = []

    override func setUp() {
        super.setUp()
        session = MockHwDeviceSession()
        deletedWalletIds = []
    }

    // MARK: - connectWithPassphrase

    func testOpensTheHiddenWalletAndReturnsItsIdentity() async throws {
        session.storedDevices = [makeDevice(walletId: standardWalletId)]
        session.connectedDeviceId = "dev1"
        session.connectedFeatures = makeFeatures(passphraseProtection: true)
        session.openedWalletIdOnHidden = hiddenWalletId
        let manager = makeManager()

        let opened = try await manager.connectWithPassphrase(deviceId: "dev1", passphrase: "correct horse")

        XCTAssertEqual(opened, hiddenWalletId)
        XCTAssertEqual(session.openCalls.map(\.mode), [.passphraseHost])
        XCTAssertEqual(session.openCalls.first?.passphrase, "correct horse")
    }

    /// A device with passphrase protection off ignores the passphrase and reopens the standard
    /// wallet, which would surface as "already added" and leave the user retyping something that
    /// can never take effect.
    func testRefusesADeviceThatCannotOpenHiddenWallets() async {
        session.storedDevices = [makeDevice(walletId: standardWalletId)]
        session.connectedDeviceId = "dev1"
        session.connectedFeatures = makeFeatures(passphraseProtection: false)
        let manager = makeManager()

        await assertThrows(HwPassphraseError.protectionDisabled) {
            _ = try await manager.connectWithPassphrase(deviceId: "dev1", passphrase: "anything")
        }
        XCTAssertTrue(session.openCalls.isEmpty, "the device is never asked to open a hidden wallet")
    }

    /// A session that dropped between pairing and this call is a reconnect problem; telling the user
    /// to enable passphrase protection they already have on would send them to Trezor Suite for
    /// nothing.
    func testASessionThatDroppedIsNotReportedAsProtectionBeingOff() async {
        session.storedDevices = [makeDevice(walletId: standardWalletId)]
        session.connectedDeviceId = "dev1"
        session.connectedFeatures = nil
        let manager = makeManager()

        do {
            _ = try await manager.connectWithPassphrase(deviceId: "dev1", passphrase: "correct horse")
            XCTFail("expected a reconnect failure")
        } catch is HwPassphraseError {
            XCTFail("a missing session must not be reported as passphrase protection being off")
        } catch {
            XCTAssertTrue(session.openCalls.isEmpty, "the device is never asked to open a hidden wallet")
        }
    }

    func testReportsAPassphraseWalletThatIsAlreadyWatched() async {
        session.storedDevices = [
            makeDevice(walletId: standardWalletId),
            makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: hiddenWalletId, passphraseProtected: true),
        ]
        session.connectedDeviceId = "dev1"
        session.connectedFeatures = makeFeatures(passphraseProtection: true)
        session.openedWalletIdOnHidden = hiddenWalletId
        let manager = makeManager()

        await assertThrows(HwPassphraseError.alreadyAdded) {
            _ = try await manager.connectWithPassphrase(deviceId: "dev1", passphrase: "already used")
        }
    }

    // MARK: - ensureConnected

    func testAcceptsASessionAlreadyOpenOnTheRequestedWallet() async throws {
        session.storedDevices = [makeDevice(walletId: standardWalletId)]
        session.connectedDeviceId = "dev1"
        session.connectedWalletId = standardWalletId
        let manager = makeManager()

        try await manager.ensureConnected(walletId: standardWalletId)

        XCTAssertEqual(session.ensureCalls, ["dev1"])
        XCTAssertTrue(session.openCalls.isEmpty, "no reopen is needed")
    }

    func testRetryWaitsForScheduledStaleSessionCleanup() async throws {
        session.storedDevices = [makeDevice(walletId: standardWalletId)]
        session.connectedDeviceId = "dev1"
        session.connectedWalletId = standardWalletId
        session.blocksStaleDisconnect = true
        let manager = makeManager()
        let cleanupStarted = expectation(description: "stale cleanup started")
        session.onStaleDisconnect = { cleanupStarted.fulfill() }

        manager.scheduleStaleSessionCleanup(walletId: standardWalletId)
        await fulfillment(of: [cleanupStarted], timeout: 1)

        let retry = Task { @MainActor in
            try await manager.ensureConnected(walletId: standardWalletId)
        }
        await Task.yield()

        XCTAssertEqual(session.staleDisconnects, ["dev1"])
        XCTAssertTrue(session.ensureCalls.isEmpty)

        session.finishStaleDisconnect()
        try await retry.value

        XCTAssertEqual(session.ensureCalls, ["dev1"])
    }

    /// A session reporting no identity may be holding any seed the device has open, so it is not
    /// accepted on trust. A wallet that needs no secret can simply be reopened, which re-reads the
    /// accounts that failed to resolve.
    func testReopensTheStandardWalletWhenTheSessionReportedNoIdentity() async throws {
        session.storedDevices = [makeDevice(walletId: standardWalletId)]
        session.connectedDeviceId = "dev1"
        session.connectedWalletId = nil
        session.openedWalletIdOnStandard = standardWalletId
        let manager = makeManager()

        try await manager.ensureConnected(walletId: standardWalletId)

        XCTAssertEqual(session.openCalls.map(\.mode), [.standard])
    }

    /// A hidden wallet is only ever opened by proving its identity, so a session that resolved to
    /// none is never one — accepting it would compose and sign against whichever seed is loaded.
    func testDemandsThePassphraseWhenTheSessionResolvedToNoIdentity() async {
        session.storedDevices = [
            makeDevice(walletId: standardWalletId),
            makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: hiddenWalletId, passphraseProtected: true),
        ]
        session.connectedDeviceId = "dev1"
        session.connectedWalletId = nil
        let manager = makeManager()

        await assertThrows(HwPassphraseError.required) {
            try await manager.ensureConnected(walletId: hiddenWalletId)
        }
    }

    func testReopensTheStandardWalletWhenAnotherIdentityHoldsTheSession() async throws {
        session.storedDevices = [
            makeDevice(walletId: standardWalletId),
            makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: hiddenWalletId, passphraseProtected: true),
        ]
        session.connectedDeviceId = "dev1"
        session.connectedWalletId = hiddenWalletId
        session.openedWalletIdOnStandard = standardWalletId
        let manager = makeManager()

        try await manager.ensureConnected(walletId: standardWalletId)

        XCTAssertEqual(session.openCalls.map(\.mode), [.standard])
    }

    /// Only the passphrase reopens a hidden wallet, so there is nothing to try automatically.
    func testDemandsThePassphraseWhenAnotherIdentityHoldsTheSession() async {
        session.storedDevices = [
            makeDevice(walletId: standardWalletId),
            makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: hiddenWalletId, passphraseProtected: true),
        ]
        session.connectedDeviceId = "dev1"
        session.connectedWalletId = standardWalletId
        let manager = makeManager()

        await assertThrows(HwPassphraseError.required) {
            try await manager.ensureConnected(walletId: hiddenWalletId)
        }
        XCTAssertTrue(session.openCalls.isEmpty)
    }

    /// The device is not holding this wallet at all — a different seed, or accounts that no longer
    /// resolve to it. Reporting it as a missing passphrase would raise a prompt that cannot open a
    /// wallet which needs no secret, and every entry would come back a mismatch.
    func testReportsAReconnectFailureWhenTheStandardWalletCannotBeReopened() async {
        session.storedDevices = [makeDevice(walletId: standardWalletId)]
        session.connectedDeviceId = "dev1"
        session.connectedWalletId = strayWalletId
        session.openedWalletIdOnStandard = strayWalletId
        let manager = makeManager()

        do {
            try await manager.ensureConnected(walletId: standardWalletId)
            XCTFail("expected a reconnect failure")
        } catch is HwPassphraseError {
            XCTFail("a wallet with no passphrase must not be reported as needing one")
        } catch {
            XCTAssertEqual(session.openCalls.map(\.mode), [.standard], "the standard reopen was attempted first")
        }
    }

    // MARK: - needsPassphrase

    func testNeedsThePassphraseOnlyWhileTheHiddenWalletIsNotTheLiveSession() {
        session.storedDevices = [
            makeDevice(walletId: standardWalletId),
            makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: hiddenWalletId, passphraseProtected: true),
        ]
        session.connectedDeviceId = "dev1"
        let manager = makeManager()

        session.connectedWalletId = standardWalletId
        XCTAssertTrue(manager.needsPassphrase(walletId: hiddenWalletId))
        XCTAssertFalse(manager.needsPassphrase(walletId: standardWalletId), "the standard wallet needs no secret")

        session.connectedWalletId = hiddenWalletId
        XCTAssertFalse(manager.needsPassphrase(walletId: hiddenWalletId), "its session is already open")
    }

    // MARK: - warmUpConnection

    /// A warm-up cannot ask for a passphrase, so warming up a hidden wallet would open the standard
    /// wallet on the very device the transfer is about to need.
    func testDoesNotWarmUpAHiddenWalletWhoseSessionIsGone() {
        session.storedDevices = [
            makeDevice(walletId: standardWalletId),
            makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: hiddenWalletId, passphraseProtected: true),
        ]
        session.connectedWalletId = nil
        let manager = makeManager()

        manager.warmUpConnection(walletId: hiddenWalletId)

        XCTAssertTrue(session.warmUpCalls.isEmpty)
    }

    func testWarmsUpAWalletThatNeedsNoPassphrase() {
        session.storedDevices = [makeDevice(walletId: standardWalletId)]
        let manager = makeManager()

        manager.warmUpConnection(walletId: standardWalletId)

        XCTAssertEqual(session.warmUpCalls, ["dev1"])
    }

    // MARK: - reconnectWithPassphrase

    func testReopensAHiddenWalletWithNoLiveSession() async throws {
        session.storedDevices = [
            makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: hiddenWalletId, passphraseProtected: true),
        ]
        session.connectedDeviceId = nil
        session.openedWalletIdOnHidden = hiddenWalletId
        let manager = makeManager()

        try await manager.reconnectWithPassphrase(walletId: hiddenWalletId, passphrase: "correct horse")

        XCTAssertEqual(session.openCalls.map(\.mode), [.passphraseHost])
        XCTAssertTrue(session.staleDisconnects.isEmpty)
    }

    /// The device does not reject a wrong passphrase — it silently derives another wallet — so the
    /// mismatch is what stands between a typo and a signature from the wrong seed.
    func testRefusesAPassphraseThatOpensADifferentWallet() async {
        let stray = makeDevice(xpubs: ["nativeSegwit": "zStray"], walletId: strayWalletId, passphraseProtected: true)
        session.storedDevices = [
            makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: hiddenWalletId, passphraseProtected: true),
        ]
        session.openedWalletIdOnHidden = strayWalletId
        session.writesEntryOnHiddenOpen = stray
        let manager = makeManager()

        await assertThrows(HwPassphraseError.mismatch) {
            try await manager.reconnectWithPassphrase(walletId: hiddenWalletId, passphrase: "wrong")
        }
        await manager.drainPendingPersists()

        XCTAssertEqual(session.forgottenWalletIds, [strayWalletId], "the wallet a typo opened is dropped")
        XCTAssertEqual(deletedWalletIds, [strayWalletId], "its activities go with it")
        XCTAssertEqual(session.staleDisconnects, ["dev1"], "the session it opened is torn down")
        // The stray is a real wallet the user owns, and reading its accounts already consumed any
        // name restored for it into the entry being forgotten, so the name has to go back.
        XCTAssertEqual(
            session.forgottenPendingNames.compactMap { $0 }.map(\.walletId),
            [strayWalletId],
            "its backup data is kept"
        )
    }

    /// An account read that failed says nothing about which wallet the session holds, so calling it a
    /// wrong passphrase would send the user to re-enter one that may well have been right.
    func testAnUnreadableReopenIsNotReportedAsAWrongPassphrase() async {
        session.storedDevices = [
            makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: hiddenWalletId, passphraseProtected: true),
        ]
        session.openedWalletIdOnHidden = nil // the open succeeded, its accounts did not resolve
        let manager = makeManager()

        do {
            try await manager.reconnectWithPassphrase(walletId: hiddenWalletId, passphrase: "correct horse")
            XCTFail("expected the read failure to be reported")
        } catch is HwPassphraseError {
            XCTFail("an unreadable session must not be reported as a wrong passphrase")
        } catch {
            XCTAssertEqual(session.staleDisconnects, ["dev1"], "the unusable session is torn down")
            XCTAssertTrue(session.forgottenWalletIds.isEmpty, "there is no stray wallet to drop")
        }
    }

    /// A wallet that was already watched before the reopen is not a stray, so it must survive.
    func testKeepsAnAlreadyWatchedWalletWhenThePassphraseOpensIt() async {
        session.storedDevices = [
            makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: hiddenWalletId, passphraseProtected: true),
            makeDevice(xpubs: ["nativeSegwit": "zOther"], walletId: strayWalletId, passphraseProtected: true),
        ]
        session.openedWalletIdOnHidden = strayWalletId
        let manager = makeManager()

        await assertThrows(HwPassphraseError.mismatch) {
            try await manager.reconnectWithPassphrase(walletId: hiddenWalletId, passphrase: "the other one")
        }
        await manager.drainPendingPersists()

        XCTAssertTrue(session.forgottenWalletIds.isEmpty)
        XCTAssertTrue(deletedWalletIds.isEmpty)
    }

    // MARK: - signFunding

    func testRefusesToSignWhenTheSessionBelongsToAnotherIdentity() async {
        session.storedDevices = [
            makeDevice(walletId: standardWalletId),
            makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: hiddenWalletId, passphraseProtected: true),
        ]
        session.connectedDeviceId = "dev1"
        session.connectedWalletId = standardWalletId
        let manager = makeManager()

        await assertThrows(HwPassphraseError.required) {
            _ = try await manager.signFunding(walletId: hiddenWalletId, funding: makeFunding())
        }
    }

    /// The device may have opened a hidden wallet and then failed the account read, which looks
    /// exactly like a session that opened nothing — so signing for the standard wallet on an
    /// unresolved session would hand the device a transaction derived from another seed's keys.
    func testRefusesToSignForTheStandardWalletWhenTheSessionResolvedToNoIdentity() async {
        session.storedDevices = [makeDevice(walletId: standardWalletId)]
        session.connectedDeviceId = "dev1"
        session.connectedWalletId = nil
        let manager = makeManager()

        do {
            _ = try await manager.signFunding(walletId: standardWalletId, funding: makeFunding())
            XCTFail("expected the unprovable session to be refused")
        } catch is HwPassphraseError {
            XCTFail("a wallet with no passphrase must not be reported as needing one")
        } catch {
            // A reconnect failure: the device is not provably holding this wallet.
        }
    }

    /// An account read that failed leaves a live session reporting no identity. Signing then would
    /// hand the device a transaction derived from another wallet's keys.
    func testRefusesToSignForAHiddenWalletWhenTheSessionResolvedToNoIdentity() async {
        session.storedDevices = [
            makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: hiddenWalletId, passphraseProtected: true),
        ]
        session.connectedDeviceId = "dev1"
        session.connectedWalletId = nil
        let manager = makeManager()

        await assertThrows(HwPassphraseError.required) {
            _ = try await manager.signFunding(walletId: hiddenWalletId, funding: makeFunding())
        }
    }

    // MARK: - removeWallet

    func testRemovingAWalletForgetsOnlyThatIdentity() async throws {
        session.storedDevices = [
            makeDevice(walletId: standardWalletId),
            makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: hiddenWalletId, passphraseProtected: true),
        ]
        let manager = makeManager()

        try await manager.removeWallet(walletId: hiddenWalletId, keepBackupData: false)
        await manager.drainPendingPersists()

        XCTAssertEqual(session.forgottenWalletIds, [hiddenWalletId])
        XCTAssertEqual(deletedWalletIds, [hiddenWalletId])
        XCTAssertEqual(session.storedDevices.compactMap(\.resolvedWalletId), [standardWalletId])
    }

    // MARK: - Helpers

    private let standardWalletId = "trezor:standard"
    private let hiddenWalletId = "trezor:hidden"
    private let strayWalletId = "trezor:stray"

    private func makeManager() -> HwWalletManager {
        HwWalletManager(
            session: session,
            watcherService: NoopWatcher(),
            monitoredTypes: { ["nativeSegwit"] },
            electrumUrl: { "ssl://test:1" },
            network: { .regtest },
            persistSnapshot: { _ in },
            deleteActivities: { [weak self] in self?.deletedWalletIds.append($0) }
        )
    }

    private func makeDevice(
        id: String = "dev1",
        xpubs: [String: String] = ["nativeSegwit": "zStandard"],
        walletId: String,
        passphraseProtected: Bool = false
    ) -> TrezorKnownDevice {
        TrezorKnownDevice(
            id: id,
            name: "Trezor",
            path: "ble://\(id)",
            transportType: "bluetooth",
            model: "Safe 5",
            lastConnectedAt: Date(timeIntervalSince1970: 1000),
            xpubs: xpubs,
            walletId: walletId,
            passphraseProtected: passphraseProtected
        )
    }

    private func makeFunding() -> HwFundingTransaction {
        HwFundingTransaction(psbt: "psbt", miningFeeSats: 141, feeRate: 1, totalSpent: 43186, satsPerVByte: 1)
    }

    private func assertThrows(
        _ expected: HwPassphraseError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as HwPassphraseError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}

private func makeFeatures(passphraseProtection: Bool? = nil) -> TrezorFeatures {
    TrezorFeatures(
        vendor: "trezor.io",
        model: "Safe 5",
        label: "Trezor",
        deviceId: "trezor-id",
        majorVersion: 2,
        minorVersion: 8,
        patchVersion: 0,
        pinProtection: false,
        unlocked: true,
        passphraseProtection: passphraseProtection,
        initialized: true,
        needsBackup: false,
        passphraseEntryCapable: false
    )
}
