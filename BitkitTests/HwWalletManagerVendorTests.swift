@testable import Bitkit
import BitkitCore
import XCTest

/// Covers how `HwWalletManager` routes device calls by the vendor stored on a wallet's entries, and
/// keeps a single vendor on the radio, adapting the Jade cases in bitkit-android's
/// `HwWalletRepoTest`. Both sessions are fakes writing to one ordered log, so the tests can assert
/// that the other vendor is released before a device is reached.
@MainActor
final class HwWalletManagerVendorTests: XCTestCase {
    // MARK: - Fakes

    @MainActor
    private final class CallLog {
        private(set) var entries: [String] = []

        func record(_ entry: String) {
            entries.append(entry)
        }
    }

    private final class FakeTrezorSession: TrezorSessioning {
        private let log: CallLog

        var storedDevices: [HwKnownDevice] = []
        var connectedDeviceId: String?
        var connectedWalletId: String?
        var connectedFeatures: TrezorFeatures?
        var isSessionActive = false
        var knownBluetoothIds: Set<String> = []

        private(set) var openCalls: [TrezorWalletMode] = []
        private(set) var staleDisconnects: [String] = []
        private(set) var warmUpCalls: [String] = []
        private(set) var forgottenWalletIds: [String] = []
        private(set) var renameCalls: [(walletId: String, newName: String)] = []
        private(set) var releaseCalls = 0
        private(set) var autoReconnectCalls = 0

        init(log: CallLog) {
            self.log = log
        }

        func ensureConnected(deviceId: String) async throws {
            log.record("trezor.ensure:\(deviceId)")
        }

        @discardableResult
        func connectWithWalletMode(
            deviceId: String,
            mode: TrezorWalletMode,
            passphrase _: String
        ) async throws -> TrezorFeatures {
            log.record("trezor.open:\(deviceId)")
            openCalls.append(mode)
            return TrezorFeatures(
                vendor: "trezor.io",
                model: "Safe 5",
                label: "Trezor",
                deviceId: "trezor-id",
                majorVersion: 2,
                minorVersion: 8,
                patchVersion: 0,
                pinProtection: false,
                unlocked: true,
                passphraseProtection: true,
                initialized: true,
                needsBackup: false,
                passphraseEntryCapable: false
            )
        }

        func disconnectStaleSession(deviceId: String) async {
            log.record("trezor.stale:\(deviceId)")
            staleDisconnects.append(deviceId)
        }

        func releaseSession() async {
            log.record("trezor.release")
            releaseCalls += 1
            isSessionActive = false
            connectedDeviceId = nil
            connectedWalletId = nil
        }

        func autoReconnect() async {
            log.record("trezor.autoReconnect")
            autoReconnectCalls += 1
        }

        func isKnownBluetoothDevice(deviceId: String) -> Bool {
            knownBluetoothIds.contains(deviceId)
        }

        func warmUpConnection(deviceId: String) {
            warmUpCalls.append(deviceId)
        }

        func forgetWallet(walletId: String, pendingName _: PendingHwWalletName?) async {
            forgottenWalletIds.append(walletId)
            storedDevices.removeAll { $0.resolvedWalletId == walletId }
        }

        func renameWallet(walletId: String, newName: String) {
            renameCalls.append((walletId, newName))
        }
    }

    private final class FakeJadeSession: JadeSessioning {
        private let log: CallLog

        var storedDevices: [HwKnownDevice] = []
        var connectedDeviceId: String?
        var connectedWalletId: String?
        var isSessionActive = false
        var knownBluetoothIds: Set<String> = []
        var ensureError: Error?
        var verifyErrors: [Error] = []
        var fingerprint = "deadbeef"
        var completedTransaction = CompletedTransaction(serializedTx: "rawtx", txid: "txid")
        var blocksEnsure = false
        var onEnsure: (() -> Void)?
        private var ensureContinuation: CheckedContinuation<Void, Never>?

        private(set) var verifyCalls: [(addressType: AddressScriptType, derivationPath: String, expectedAddress: String)] = []
        private(set) var signedPsbts: [String] = []
        private(set) var staleDisconnects: [String] = []
        private(set) var warmUpCalls: [String] = []
        private(set) var forgottenWalletIds: [String] = []
        private(set) var renameCalls: [(walletId: String, newName: String)] = []
        private(set) var releaseCalls = 0
        private(set) var startAutoReconnectCalls = 0

        init(log: CallLog) {
            self.log = log
        }

        func ensureConnected(deviceId: String) async throws {
            log.record("jade.ensure:\(deviceId)")
            onEnsure?()
            if blocksEnsure {
                await withCheckedContinuation { ensureContinuation = $0 }
            }
            if let ensureError {
                throw ensureError
            }
            connectedDeviceId = deviceId
        }

        func finishEnsure() {
            blocksEnsure = false
            ensureContinuation?.resume()
            ensureContinuation = nil
        }

        func verifyAddress(addressType: AddressScriptType, derivationPath: String, expectedAddress: String) async throws {
            log.record("jade.verify")
            verifyCalls.append((addressType, derivationPath, expectedAddress))
            if !verifyErrors.isEmpty {
                throw verifyErrors.removeFirst()
            }
        }

        func masterFingerprint() async throws -> String {
            log.record("jade.fingerprint")
            return fingerprint
        }

        func signPsbt(_ psbtBase64: String) async throws -> CompletedTransaction {
            log.record("jade.sign")
            signedPsbts.append(psbtBase64)
            return completedTransaction
        }

        func disconnectStaleSession(deviceId: String) async {
            log.record("jade.stale:\(deviceId)")
            staleDisconnects.append(deviceId)
        }

        func releaseSession() async {
            log.record("jade.release")
            releaseCalls += 1
            isSessionActive = false
            connectedDeviceId = nil
            connectedWalletId = nil
        }

        func isKnownBluetoothDevice(deviceId: String) -> Bool {
            knownBluetoothIds.contains(deviceId)
        }

        func warmUpConnection(deviceId: String) {
            warmUpCalls.append(deviceId)
        }

        func forgetWallet(walletId: String, pendingName _: PendingHwWalletName?) async {
            forgottenWalletIds.append(walletId)
            storedDevices.removeAll { $0.resolvedWalletId == walletId }
        }

        func renameWallet(walletId: String, newName: String) {
            renameCalls.append((walletId, newName))
        }

        func startAutoReconnect() {
            log.record("jade.startAutoReconnect")
            startAutoReconnectCalls += 1
        }

        func onAppBackgrounded() {
            log.record("jade.backgrounded")
        }

        func onAppBecameActive() {
            log.record("jade.active")
        }

        func resetForWipe() async {
            log.record("jade.resetForWipe")
        }
    }

    private final class NoopWatcher: OnChainWatcherServicing, @unchecked Sendable {
        func startWatcher(params _: WatcherParams, listener _: EventListener) async throws {}
        func stopWatcher(watcherId _: String) throws {}
        func stopAllWatchers() {}
    }

    // MARK: - Setup

    private static let storageKey = "trezor.knownDevices"
    private static let pendingNamesKey = "trezor.pendingWalletNames"

    private let trezorDeviceId = "dev1"
    private let trezorWalletId = "trezor:wallet"
    private let jadeDeviceId = "jade:bluetooth:246F288F6B64"
    private let jadeWalletId = "jade:wallet"

    private var log = CallLog()
    private var trezor: FakeTrezorSession!
    private var jade: FakeJadeSession!
    private var savedDefaults: Data?
    private var savedPendingNames: [String: String]?

    override func setUp() {
        super.setUp()
        log = CallLog()
        trezor = FakeTrezorSession(log: log)
        jade = FakeJadeSession(log: log)
        savedDefaults = UserDefaults.standard.data(forKey: Self.storageKey)
        savedPendingNames = UserDefaults.standard.dictionary(forKey: Self.pendingNamesKey) as? [String: String]
        HwKnownDeviceStorage.removeAll()
    }

    override func tearDown() {
        HwKnownDeviceStorage.removeAll()
        if let savedDefaults {
            UserDefaults.standard.set(savedDefaults, forKey: Self.storageKey)
        }
        if let savedPendingNames {
            UserDefaults.standard.set(savedPendingNames, forKey: Self.pendingNamesKey)
        }
        trezor = nil
        jade = nil
        super.tearDown()
    }

    // MARK: - Wallet identity

    func testSameSeedOnTrezorAndJadeStaysTwoWallets() {
        let xpubs = ["nativeSegwit": "zSharedSeed"]
        let manager = makeManager()

        manager.updateDevices(
            knownDevices: [
                makeTrezorEntry(xpubs: xpubs, walletId: nil),
                makeJadeEntry(xpubs: xpubs, walletId: nil),
            ],
            connectedDeviceId: nil
        )

        XCTAssertEqual(manager.wallets.count, 2)
        XCTAssertEqual(Set(manager.wallets.map(\.vendor)), [.trezor, .blockstream])
        XCTAssertTrue(manager.wallets.first { $0.vendor == .trezor }?.walletId.hasPrefix("trezor:") == true)
        XCTAssertTrue(manager.wallets.first { $0.vendor == .blockstream }?.walletId.hasPrefix("jade:") == true)
    }

    func testReconnectTimeoutFollowsTheVendor() {
        trezor.storedDevices = [makeTrezorEntry()]
        jade.storedDevices = [makeJadeEntry()]
        let manager = makeManager()

        XCTAssertEqual(manager.reconnectTimeout(walletId: trezorWalletId), 30)
        XCTAssertEqual(manager.reconnectTimeout(walletId: jadeWalletId), 300)
        XCTAssertEqual(manager.reconnectTimeout(walletId: "trezor:unknown"), 30)
    }

    // MARK: - One vendor at a time

    func testEnsuringAJadeWalletReleasesTheTrezorFirst() async throws {
        trezor.storedDevices = [makeTrezorEntry()]
        jade.storedDevices = [makeJadeEntry()]
        trezor.isSessionActive = true
        let manager = makeManager()

        try await manager.ensureConnected(walletId: jadeWalletId)

        XCTAssertEqual(log.entries, ["trezor.release", "jade.ensure:\(jadeDeviceId)"])
    }

    func testEnsuringATrezorWalletReleasesTheJadeFirst() async throws {
        trezor.storedDevices = [makeTrezorEntry()]
        trezor.connectedWalletId = trezorWalletId
        jade.storedDevices = [makeJadeEntry()]
        jade.isSessionActive = true
        let manager = makeManager()

        try await manager.ensureConnected(walletId: trezorWalletId)

        XCTAssertEqual(log.entries, ["jade.release", "trezor.ensure:\(trezorDeviceId)"])
    }

    func testEnsuringLeavesAnIdleOtherVendorAlone() async throws {
        trezor.storedDevices = [makeTrezorEntry()]
        trezor.connectedWalletId = trezorWalletId
        jade.storedDevices = [makeJadeEntry()]
        let manager = makeManager()

        try await manager.ensureConnected(walletId: trezorWalletId)
        try await manager.ensureConnected(walletId: jadeWalletId)

        XCTAssertEqual(log.entries, ["trezor.ensure:\(trezorDeviceId)", "jade.ensure:\(jadeDeviceId)"])
    }

    /// A Jade holds a single wallet, so a session that resolved to another one is the wrong device.
    func testEnsureRejectsAJadeHoldingAnotherWallet() async {
        jade.storedDevices = [makeJadeEntry()]
        jade.connectedWalletId = "jade:other"
        let manager = makeManager()

        do {
            try await manager.ensureConnected(walletId: jadeWalletId)
            XCTFail("expected the other wallet's session to be refused")
        } catch {
            XCTAssertEqual(log.entries, ["jade.ensure:\(jadeDeviceId)"])
        }
    }

    /// A session whose accounts could not be read proves nothing either way; signing still checks
    /// which device it is.
    func testEnsureAcceptsAJadeThatResolvedNoWallet() async throws {
        jade.storedDevices = [makeJadeEntry()]
        jade.connectedWalletId = nil
        let manager = makeManager()

        try await manager.ensureConnected(walletId: jadeWalletId)

        XCTAssertEqual(jade.connectedDeviceId, jadeDeviceId)
    }

    func testPairingThroughWithVendorSessionReleasesTheOtherVendor() async throws {
        trezor.isSessionActive = true
        let manager = makeManager()

        let result = try await manager.withVendorSession(.blockstream) {
            log.record("pair")
            return 7
        }

        XCTAssertEqual(result, 7)
        XCTAssertEqual(log.entries, ["trezor.release", "pair"])
    }

    func testSessionOperationsRunOneAtATimeInArrivalOrder() async throws {
        trezor.storedDevices = [makeTrezorEntry()]
        trezor.connectedWalletId = trezorWalletId
        jade.storedDevices = [makeJadeEntry()]
        jade.blocksEnsure = true
        let jadeEnsureStarted = expectation(description: "jade ensure started")
        jade.onEnsure = { jadeEnsureStarted.fulfill() }
        let manager = makeManager()

        let jadeOperation = Task { @MainActor in
            try await manager.ensureConnected(walletId: self.jadeWalletId)
        }
        await fulfillment(of: [jadeEnsureStarted], timeout: 1)
        let trezorOperation = Task { @MainActor in
            try await manager.ensureConnected(walletId: self.trezorWalletId)
        }
        for _ in 0 ..< 5 {
            await Task.yield()
        }

        XCTAssertEqual(log.entries, ["jade.ensure:\(jadeDeviceId)"], "the Trezor waits for the Jade operation")

        jade.isSessionActive = true
        jade.finishEnsure()
        try await jadeOperation.value
        try await trezorOperation.value

        XCTAssertEqual(log.entries, ["jade.ensure:\(jadeDeviceId)", "jade.release", "trezor.ensure:\(trezorDeviceId)"])
    }

    func testACancelledOperationWaitingForTheLockNeverReachesTheDevice() async throws {
        trezor.storedDevices = [makeTrezorEntry()]
        trezor.connectedWalletId = trezorWalletId
        jade.storedDevices = [makeJadeEntry()]
        jade.blocksEnsure = true
        let jadeEnsureStarted = expectation(description: "jade ensure started")
        jade.onEnsure = { jadeEnsureStarted.fulfill() }
        let manager = makeManager()

        let jadeOperation = Task { @MainActor in
            try await manager.ensureConnected(walletId: self.jadeWalletId)
        }
        await fulfillment(of: [jadeEnsureStarted], timeout: 1)
        let trezorOperation = Task { @MainActor in
            try await manager.ensureConnected(walletId: self.trezorWalletId)
        }
        await Task.yield()
        trezorOperation.cancel()
        jade.finishEnsure()
        try await jadeOperation.value

        do {
            try await trezorOperation.value
            XCTFail("expected the queued operation to be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(log.entries, ["jade.ensure:\(jadeDeviceId)"])
    }

    // MARK: - Foreground reconnect

    func testForegroundReconnectTargetsTheConnectedJade() async {
        HwKnownDeviceStorage.saveAll([makeTrezorEntry(lastConnectedAt: 50)], vendor: .trezor)
        HwKnownDeviceStorage.saveAll([makeJadeEntry(lastConnectedAt: 0)], vendor: .blockstream)
        jade.connectedDeviceId = jadeDeviceId
        let manager = makeManager()

        await manager.reconnectOnForeground()
        await settle()

        XCTAssertEqual(jade.startAutoReconnectCalls, 1)
        XCTAssertEqual(trezor.autoReconnectCalls, 0)
    }

    func testForegroundReconnectPicksTheMostRecentlyUsedVendor() async {
        HwKnownDeviceStorage.saveAll([makeTrezorEntry(lastConnectedAt: 0)], vendor: .trezor)
        HwKnownDeviceStorage.saveAll([makeJadeEntry(lastConnectedAt: 20)], vendor: .blockstream)
        trezor.storedDevices = [makeTrezorEntry(lastConnectedAt: 0)]
        jade.storedDevices = [makeJadeEntry(lastConnectedAt: 20)]
        let manager = makeManager()

        await manager.reconnectOnForeground()
        await settle()

        XCTAssertEqual(jade.startAutoReconnectCalls, 1)
        XCTAssertEqual(trezor.autoReconnectCalls, 0)
    }

    /// On a cold launch the foreground reconnect runs before the vendor managers load their entries,
    /// so the choice has to come from what is saved.
    func testForegroundReconnectReadsSavedJadeBeforeTheManagersLoadIt() async {
        HwKnownDeviceStorage.saveAll([makeJadeEntry()], vendor: .blockstream)
        let manager = makeManager()

        await manager.reconnectOnForeground()
        await settle()

        XCTAssertEqual(jade.startAutoReconnectCalls, 1)
        XCTAssertEqual(trezor.autoReconnectCalls, 0)
    }

    func testForegroundReconnectDefaultsToTrezor() async {
        let manager = makeManager()

        await manager.reconnectOnForeground()
        await waitUntil { self.trezor.autoReconnectCalls == 1 }

        XCTAssertEqual(trezor.autoReconnectCalls, 1)
        XCTAssertEqual(jade.startAutoReconnectCalls, 0)
    }

    func testForegroundReconnectOfATrezorReleasesAPendingJadeFirst() async {
        trezor.connectedDeviceId = trezorDeviceId
        jade.isSessionActive = true
        let manager = makeManager()

        await manager.reconnectOnForeground()
        await waitUntil { self.trezor.autoReconnectCalls == 1 }

        XCTAssertEqual(log.entries, ["jade.release", "trezor.autoReconnect"])
    }

    // MARK: - Bluetooth restored

    func testBluetoothRestoredStartsASilentJadeReconnect() {
        jade.storedDevices = [makeJadeEntry()]
        let manager = makeManager()

        manager.onJadeBluetoothRestored()

        XCTAssertEqual(jade.startAutoReconnectCalls, 1)
    }

    func testBluetoothRestoredLeavesAnActiveTrezorAlone() {
        jade.storedDevices = [makeJadeEntry()]
        trezor.isSessionActive = true
        let manager = makeManager()

        manager.onJadeBluetoothRestored()

        XCTAssertEqual(jade.startAutoReconnectCalls, 0)
        XCTAssertEqual(trezor.releaseCalls, 0)
    }

    func testBluetoothRestoredWaitsForTheForegroundAndAPairedJade() {
        let manager = makeManager()

        manager.onJadeBluetoothRestored()
        XCTAssertEqual(jade.startAutoReconnectCalls, 0, "nothing is paired")

        jade.storedDevices = [makeJadeEntry()]
        manager.onAppBackgrounded()
        manager.onJadeBluetoothRestored()
        XCTAssertEqual(jade.startAutoReconnectCalls, 0, "the app is in the background")

        manager.onAppBecameActive()
        manager.onJadeBluetoothRestored()
        XCTAssertEqual(jade.startAutoReconnectCalls, 1)
    }

    // MARK: - Passphrase

    func testPassphraseIsRejectedForJade() async {
        trezor.storedDevices = [makeTrezorEntry()]
        trezor.isSessionActive = true
        jade.storedDevices = [makeJadeEntry()]
        let manager = makeManager()

        await assertThrows(HwPassphraseError.protectionDisabled) {
            _ = try await manager.connectWithPassphrase(deviceId: self.jadeDeviceId, passphrase: "correct horse")
        }
        await assertThrows(HwPassphraseError.protectionDisabled) {
            try await manager.reconnectWithPassphrase(walletId: self.jadeWalletId, passphrase: "correct horse")
        }

        XCTAssertFalse(manager.needsPassphrase(walletId: jadeWalletId))
        XCTAssertTrue(trezor.openCalls.isEmpty)
        XCTAssertEqual(trezor.releaseCalls, 0, "a refused request leaves the Trezor session alone")
    }

    // MARK: - Receive address verification

    func testVerifiesAJadeAddressOnTheDevice() async throws {
        jade.storedDevices = [makeJadeEntry()]
        var trezorAddressCalls = 0
        let manager = makeManager(addressProvider: { _ in
            trezorAddressCalls += 1
            throw TrezorError.DeviceDisconnected
        })
        let receiveAddress = makeReceiveAddress()

        try await manager.verifyReceiveAddress(walletId: jadeWalletId, receiveAddress: receiveAddress)

        XCTAssertEqual(trezorAddressCalls, 0, "the Trezor address call is never made for a Jade")
        XCTAssertEqual(log.entries, ["jade.ensure:\(jadeDeviceId)", "jade.verify"])
        XCTAssertEqual(jade.verifyCalls.first?.addressType, .nativeSegwit)
        XCTAssertEqual(jade.verifyCalls.first?.derivationPath, receiveAddress.path)
        XCTAssertEqual(jade.verifyCalls.first?.expectedAddress, receiveAddress.address)
    }

    func testReportsAJadeAddressMismatch() async {
        jade.storedDevices = [makeJadeEntry()]
        jade.verifyErrors = [Bitkit.AppError(error: JadeError.AddressMismatch(expected: "bcrt1qreceive", returned: "bcrt1qother"))]
        let manager = makeManager()

        do {
            try await manager.verifyReceiveAddress(walletId: jadeWalletId, receiveAddress: makeReceiveAddress())
            XCTFail("expected the mismatch to be reported")
        } catch {
            XCTAssertEqual(error.localizedDescription, t("hardware__verify_address_error"))
        }
        XCTAssertTrue(jade.staleDisconnects.isEmpty, "a mismatch is not a broken session")
    }

    func testRetriesJadeVerificationAfterAStaleSession() async throws {
        jade.storedDevices = [makeJadeEntry()]
        jade.verifyErrors = [JadeError.Timeout]
        let manager = makeManager()

        try await manager.verifyReceiveAddress(walletId: jadeWalletId, receiveAddress: makeReceiveAddress())

        XCTAssertEqual(log.entries, [
            "jade.ensure:\(jadeDeviceId)",
            "jade.verify",
            "jade.stale:\(jadeDeviceId)",
            "jade.ensure:\(jadeDeviceId)",
            "jade.verify",
        ])
    }

    func testDisconnectsAfterJadeVerificationRetryFails() async {
        jade.storedDevices = [makeJadeEntry()]
        jade.verifyErrors = [JadeError.Timeout, Bitkit.AppError(error: JadeError.DeviceDisconnected)]
        let manager = makeManager()

        do {
            try await manager.verifyReceiveAddress(walletId: jadeWalletId, receiveAddress: makeReceiveAddress())
            XCTFail("expected verification to fail")
        } catch {
            XCTAssertTrue(error.isJadeSessionFailure())
        }

        XCTAssertEqual(jade.verifyCalls.count, 2)
        XCTAssertEqual(jade.staleDisconnects, [jadeDeviceId, jadeDeviceId])
    }

    func testAJadeVerificationDeclinedOnTheDeviceIsNotRetried() async {
        jade.storedDevices = [makeJadeEntry()]
        jade.verifyErrors = [JadeError.UserCancelled]
        let manager = makeManager()

        do {
            try await manager.verifyReceiveAddress(walletId: jadeWalletId, receiveAddress: makeReceiveAddress())
            XCTFail("expected the cancellation to be rethrown")
        } catch {
            XCTAssertTrue(error.isJadeUserCancellation())
        }

        XCTAssertEqual(jade.verifyCalls.count, 1)
        XCTAssertTrue(jade.staleDisconnects.isEmpty)
    }

    // MARK: - Funding

    /// Without the Jade's key origins in the PSBT the device finds nothing of its own to sign.
    func testComposingForJadeUsesItsMasterFingerprint() async throws {
        let entry = makeJadeEntry()
        jade.storedDevices = [entry]
        var composedParams: ComposeParams?
        let manager = makeManager(composeProvider: { [log] params in
            log.record("compose")
            composedParams = params
            return [.success(psbt: "psbt", fee: 141, feeRate: 2, totalSpent: 1141)]
        })
        manager.updateDevices(knownDevices: [entry], connectedDeviceId: nil)

        let funding = try await manager.composeFundingTransaction(
            walletId: jadeWalletId,
            address: "bcrt1qdestination",
            sats: 1000,
            satsPerVByte: 2
        )

        XCTAssertEqual(funding.psbt, "psbt")
        XCTAssertEqual(composedParams?.wallet.fingerprint, "deadbeef")
        XCTAssertEqual(composedParams?.wallet.extendedKey, "zJade")
        XCTAssertEqual(log.entries, ["jade.ensure:\(jadeDeviceId)", "jade.fingerprint", "compose"])
    }

    func testSignFundingRefusesAJadeSessionOfAnotherWallet() async {
        jade.storedDevices = [makeJadeEntry()]
        jade.connectedDeviceId = jadeDeviceId
        jade.connectedWalletId = "jade:other"
        let manager = makeManager()

        do {
            _ = try await manager.signFunding(walletId: jadeWalletId, funding: makeFunding())
            XCTFail("expected the other wallet's session to be refused")
        } catch {
            XCTAssertTrue(jade.signedPsbts.isEmpty)
        }
    }

    func testSignFundingRefusesAnUnresolvedJadeSessionOfAnotherDevice() async {
        jade.storedDevices = [makeJadeEntry()]
        jade.connectedDeviceId = "jade:bluetooth:AAAAAAAAAAAA"
        jade.connectedWalletId = nil
        let manager = makeManager()

        do {
            _ = try await manager.signFunding(walletId: jadeWalletId, funding: makeFunding())
            XCTFail("expected another device's session to be refused")
        } catch {
            XCTAssertTrue(jade.signedPsbts.isEmpty)
        }
    }

    func testSignFundingSignsOnTheJadeHoldingTheWallet() async throws {
        jade.storedDevices = [makeJadeEntry()]
        jade.connectedDeviceId = jadeDeviceId
        jade.connectedWalletId = jadeWalletId
        let manager = makeManager()

        let signed = try await manager.signFunding(walletId: jadeWalletId, funding: makeFunding())

        XCTAssertEqual(signed.serializedTx, "rawtx")
        XCTAssertEqual(signed.miningFeeSats, 141)
        XCTAssertEqual(signed.totalSpent, 43186)
        XCTAssertEqual(jade.signedPsbts, ["psbt"])
    }

    func testSignFundingAcceptsAnUnresolvedSessionOfTheWalletsJade() async throws {
        jade.storedDevices = [makeJadeEntry()]
        jade.connectedDeviceId = jadeDeviceId
        jade.connectedWalletId = nil
        let manager = makeManager()

        _ = try await manager.signFunding(walletId: jadeWalletId, funding: makeFunding())

        XCTAssertEqual(jade.signedPsbts, ["psbt"])
    }

    // MARK: - Routed maintenance

    func testRenameAndRemoveRouteToTheWalletsVendor() async throws {
        trezor.storedDevices = [makeTrezorEntry()]
        jade.storedDevices = [makeJadeEntry()]
        let manager = makeManager()

        manager.renameWallet(walletId: jadeWalletId, newName: "Cold")
        manager.renameWallet(walletId: trezorWalletId, newName: "Hot")
        try await manager.removeWallet(walletId: jadeWalletId, keepBackupData: false)
        await manager.drainPendingPersists()

        XCTAssertEqual(jade.renameCalls.map(\.walletId), [jadeWalletId])
        XCTAssertEqual(jade.renameCalls.map(\.newName), ["Cold"])
        XCTAssertEqual(trezor.renameCalls.map(\.walletId), [trezorWalletId])
        XCTAssertEqual(jade.forgottenWalletIds, [jadeWalletId])
        XCTAssertTrue(trezor.forgottenWalletIds.isEmpty)
    }

    func testWarmUpSkipsWhileTheOtherVendorIsActive() {
        jade.storedDevices = [makeJadeEntry()]
        trezor.isSessionActive = true
        let manager = makeManager()

        manager.warmUpConnection(walletId: jadeWalletId)
        XCTAssertTrue(jade.warmUpCalls.isEmpty)
        XCTAssertEqual(trezor.releaseCalls, 0, "a warm-up never takes the radio from the other vendor")

        trezor.isSessionActive = false
        manager.warmUpConnection(walletId: jadeWalletId)
        XCTAssertEqual(jade.warmUpCalls, [jadeDeviceId])
        XCTAssertTrue(trezor.warmUpCalls.isEmpty)
    }

    func testStaleSessionCleanupRoutesToTheWalletsVendor() async {
        trezor.storedDevices = [makeTrezorEntry()]
        jade.storedDevices = [makeJadeEntry()]
        let manager = makeManager()

        await manager.disconnectStaleSession(walletId: jadeWalletId)
        await manager.disconnectStaleSession(walletId: trezorWalletId)

        XCTAssertEqual(log.entries, ["jade.stale:\(jadeDeviceId)", "trezor.stale:\(trezorDeviceId)"])
    }

    /// The wallet can be forgotten before a scheduled cleanup runs, which would leave nothing to read
    /// its vendor from.
    func testScheduledCleanupReachesTheVendorItWasScheduledFor() async {
        jade.storedDevices = [makeJadeEntry()]
        let manager = makeManager()

        manager.scheduleStaleSessionCleanup(walletId: jadeWalletId)
        jade.storedDevices = []
        await waitUntil { !self.jade.staleDisconnects.isEmpty }

        XCTAssertEqual(jade.staleDisconnects, [jadeDeviceId])
        XCTAssertTrue(trezor.staleDisconnects.isEmpty)
    }

    func testKnownBluetoothDeviceIsAskedOfTheWalletsVendor() {
        trezor.storedDevices = [makeTrezorEntry()]
        jade.storedDevices = [makeJadeEntry()]
        jade.knownBluetoothIds = [jadeDeviceId]
        let manager = makeManager()

        XCTAssertTrue(manager.isKnownBluetoothDevice(walletId: jadeWalletId))
        XCTAssertFalse(manager.isKnownBluetoothDevice(walletId: trezorWalletId))

        trezor.knownBluetoothIds = [trezorDeviceId]
        XCTAssertTrue(manager.isKnownBluetoothDevice(walletId: trezorWalletId))
    }

    // MARK: - App lifecycle

    func testLifecycleHooksReachTheJade() async {
        let manager = makeManager()

        manager.onAppBackgrounded()
        manager.onAppBecameActive()
        await manager.resetForWipe()

        XCTAssertEqual(log.entries, ["jade.backgrounded", "jade.active", "jade.resetForWipe"])
    }

    // MARK: - Helpers

    private func makeManager(
        addressProvider: @escaping HwWalletManager.AddressProvider = { _ in throw TrezorError.DeviceDisconnected },
        composeProvider: @escaping HwWalletManager.ComposeProvider = { _ in [] }
    ) -> HwWalletManager {
        HwWalletManager(
            trezorSession: trezor,
            jadeSession: jade,
            watcherService: NoopWatcher(),
            monitoredTypes: { ["nativeSegwit"] },
            electrumUrl: { "ssl://test:1" },
            network: { .regtest },
            addressProvider: addressProvider,
            composeProvider: composeProvider,
            persistSnapshot: { _ in },
            deleteActivities: { _ in }
        )
    }

    private func makeTrezorEntry(
        xpubs: [String: String] = ["nativeSegwit": "zTrezor"],
        walletId: String? = "trezor:wallet",
        lastConnectedAt: TimeInterval = 1000
    ) -> HwKnownDevice {
        HwKnownDevice(
            id: trezorDeviceId,
            name: "Trezor",
            path: "ble:\(trezorDeviceId)",
            transportType: "bluetooth",
            model: "Safe 5",
            lastConnectedAt: Date(timeIntervalSince1970: lastConnectedAt),
            xpubs: xpubs,
            walletId: walletId
        )
    }

    private func makeJadeEntry(
        xpubs: [String: String] = ["nativeSegwit": "zJade"],
        walletId: String? = "jade:wallet",
        lastConnectedAt: TimeInterval = 1000
    ) -> HwKnownDevice {
        HwKnownDevice(
            id: jadeDeviceId,
            name: "Jade 8F6B64",
            path: "ble:jade",
            transportType: "bluetooth",
            model: "Jade",
            lastConnectedAt: Date(timeIntervalSince1970: lastConnectedAt),
            xpubs: xpubs,
            walletId: walletId,
            vendor: .blockstream,
            jadeDeviceId: "246F288F6B64"
        )
    }

    private func makeReceiveAddress() -> HwReceiveAddress {
        HwReceiveAddress(address: "bcrt1qreceive", path: "m/84'/1'/0'/0/7", addressType: .nativeSegwit)
    }

    private func makeFunding() -> HwFundingTransaction {
        HwFundingTransaction(psbt: "psbt", miningFeeSats: 141, feeRate: 1, totalSpent: 43186, satsPerVByte: 1)
    }

    /// Lets a launched reconnect run, so a test can assert that one was not launched.
    private func settle() async {
        for _ in 0 ..< 10 {
            await Task.yield()
        }
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
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
