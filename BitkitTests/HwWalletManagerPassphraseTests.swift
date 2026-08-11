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

        func disconnectStaleSession(deviceId: String) async {
            staleDisconnects.append(deviceId)
        }

        func isKnownBluetoothDevice(deviceId _: String) -> Bool {
            true
        }

        func warmUpConnection(deviceId: String) {
            warmUpCalls.append(deviceId)
        }

        func forgetWallet(walletId: String) async {
            forgottenWalletIds.append(walletId)
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

    /// A session opened before its identity could be resolved reports none and stays usable.
    func testAcceptsASessionWhoseIdentityIsNotYetResolved() async throws {
        session.storedDevices = [makeDevice(walletId: standardWalletId)]
        session.connectedDeviceId = "dev1"
        session.connectedWalletId = nil
        let manager = makeManager()

        try await manager.ensureConnected(walletId: standardWalletId)

        XCTAssertTrue(session.openCalls.isEmpty)
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

    // MARK: - removeWallet

    func testRemovingAWalletForgetsOnlyThatIdentity() async {
        session.storedDevices = [
            makeDevice(walletId: standardWalletId),
            makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: hiddenWalletId, passphraseProtected: true),
        ]
        let manager = makeManager()

        await manager.removeWallet(walletId: hiddenWalletId)
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
