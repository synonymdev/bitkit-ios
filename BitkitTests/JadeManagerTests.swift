@testable import Bitkit
import BitkitCore
import XCTest

/// Ports bitkit-android's `JadeRepoTest` to `JadeManager` (cases 1-8, 11-19 and 22-27; the USB-only
/// cases 9, 10 and 20 have no iOS counterpart, and case 21 becomes the background expiration case),
/// then covers what iOS adds: teardown ordering against core, the connect epoch, the in-progress
/// flags and the background budget. Core and the transport are fakes writing to one ordered log.
@MainActor
final class JadeManagerTests: XCTestCase {
    private nonisolated static let fastTiming = JadeManager.Timing(
        backgroundRelease: 0.05,
        expirationMargin: 0.01,
        reconnectBackoff: 0.02,
        reconnectAttempts: 4,
        connectPollInterval: 0.01,
        connectMaxWait: 2
    )

    private var log: JadeCallLog!
    private var service: FakeJadeService!
    private var transport: FakeJadeTransportControl!
    private var store: InMemoryJadeKnownDeviceStore!
    private var backgroundTasks: FakeBackgroundTasks!

    override func setUp() {
        super.setUp()
        log = JadeCallLog()
        service = FakeJadeService(log: log)
        transport = FakeJadeTransportControl(log: log)
        store = InMemoryJadeKnownDeviceStore()
        backgroundTasks = FakeBackgroundTasks()
    }

    override func tearDown() {
        backgroundTasks = nil
        store = nil
        transport = nil
        service = nil
        log = nil
        super.tearDown()
    }

    // MARK: - Scan and pair (Android cases 1-6)

    func testScanListsTheLastDevicesWhileASessionIsOpen() async throws {
        service.stubs.isConnected = true
        service.stubs.listed = [JadeFixtures.device()]
        let sut = makeManager()

        let devices = try await sut.scan()

        XCTAssertEqual(devices, [JadeFixtures.device()])
        XCTAssertFalse(log.contains("service.scan"))
        XCTAssertEqual(sut.nearbyDevices, [JadeFixtures.device()])
    }

    func testPairingUnlocksALockedJadeReadsItsAccountsAndStoresTheEntry() async throws {
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.connectResult = .success(JadeFixtures.version(.locked))
        let sut = makeManager()
        _ = try await sut.scan()

        let connected = try await sut.connect(path: JadeFixtures.blePath)

        XCTAssertEqual(service.calls.unlockNetworks, [.regtest])
        XCTAssertEqual(service.calls.exportTypes, [JadeManager.allAccountTypes])
        XCTAssertEqual(store.saves.count, 1)
        let stored = try XCTUnwrap(store.saves.last?.first)
        XCTAssertEqual(store.saves.last?.count, 1)
        XCTAssertEqual(stored.id, JadeFixtures.deviceId)
        XCTAssertEqual(stored.vendor, .blockstream)
        XCTAssertEqual(stored.jadeDeviceId, JadeFixtures.efuseMac)
        XCTAssertEqual(stored.path, JadeFixtures.blePath)
        XCTAssertEqual(stored.name, JadeFixtures.advertisedName)
        XCTAssertEqual(stored.transportType, "bluetooth")
        XCTAssertEqual(stored.xpubs["nativeSegwit"], JadeFixtures.xpub)
        XCTAssertEqual(stored.model, "Jade")
        XCTAssertTrue(stored.walletId?.hasPrefix("jade:") == true, "walletId=\(stored.walletId ?? "nil")")
        XCTAssertEqual(connected.id, stored.id)
        XCTAssertEqual(connected.walletId, stored.walletId)
        XCTAssertFalse(connected.isLocked)
        XCTAssertEqual(sut.connected, connected)
        XCTAssertEqual(sut.knownDevices, [stored])
        XCTAssertTrue(sut.nearbyDevices.isEmpty)
        XCTAssertFalse(sut.isConnecting)
        XCTAssertFalse(sut.isUnlocking)
    }

    func testPairingRefusesAJadeThatHasNoWalletYet() async throws {
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.connectResult = .success(JadeFixtures.version(.uninit))
        let sut = makeManager()
        _ = try await sut.scan()

        do {
            try await sut.connect(path: JadeFixtures.blePath)
            XCTFail("an uninitialised Jade must be refused")
        } catch {
            XCTAssertEqual(error.underlyingJadeError, .DeviceUninitialized)
        }

        XCTAssertTrue(log.contains("transport.disconnect:\(JadeFixtures.blePath)"))
        XCTAssertTrue(log.contains("service.disconnect"))
        XCTAssertTrue(service.calls.unlockNetworks.isEmpty)
        XCTAssertNil(sut.connected)
        XCTAssertTrue(store.saves.isEmpty)
    }

    func testAFailedAccountExportClosesTheLinkAndTheCoreSession() async throws {
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.exportHandler = { _ in throw JadeError.IoError(errorDetails: "export failed") }
        let sut = makeManager()
        _ = try await sut.scan()

        do {
            try await sut.connect(path: JadeFixtures.blePath)
            XCTFail("the connect must fail with the export")
        } catch {}

        XCTAssertTrue(log.contains("transport.disconnect:\(JadeFixtures.blePath)"))
        XCTAssertTrue(log.contains("service.disconnect"))
        XCTAssertNil(sut.connected)
        XCTAssertTrue(store.saves.isEmpty)
    }

    func testTheAccountsAreReadAgainWithoutTaprootOnOldFirmware() async throws {
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.exportHandler = { types in
            if types.contains(.taproot) {
                throw Bitkit.AppError(error: JadeError.UnsupportedFirmware(installed: "1.0.30", required: "1.0.34"))
            }
            return JadeFixtures.accountExport()
        }
        let sut = makeManager()
        _ = try await sut.scan()

        try await sut.connect(path: JadeFixtures.blePath)

        XCTAssertEqual(service.calls.exportTypes, [JadeManager.allAccountTypes, [.legacy, .wrappedSegwit, .nativeSegwit]])
        XCTAssertNotNil(sut.connected)
    }

    func testAJadeReachedUnderANewPathRefreshesItsStoredEntry() async throws {
        store.devices = [JadeFixtures.knownEntry(path: JadeFixtures.stalePath)]
        service.stubs.scanned = [JadeFixtures.device(path: JadeFixtures.readvertisedPath)]
        let sut = makeManager()
        _ = try await sut.scan()

        try await sut.connect(path: JadeFixtures.readvertisedPath)

        let saved = try XCTUnwrap(store.saves.last)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.id, JadeFixtures.deviceId)
        XCTAssertEqual(saved.first?.path, JadeFixtures.readvertisedPath)
        XCTAssertEqual(saved.first?.walletId, JadeFixtures.walletId)
    }

    // MARK: - Known device reconnects (Android cases 7, 8 and 11-18)

    func testReconnectingAKnownJadeRejectsADifferentDevice() async throws {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.connectResult = .success(JadeFixtures.version(.ready, efuseMac: "other"))
        let sut = makeManager()

        do {
            try await sut.connectKnownDevice(deviceId: JadeFixtures.deviceId)
            XCTFail("a different Jade must be rejected")
        } catch {}

        XCTAssertGreaterThanOrEqual(log.count("service.disconnect"), 1)
        XCTAssertTrue(service.calls.exportTypes.isEmpty)
        XCTAssertNil(sut.connected)
    }

    func testReconnectingAKnownJadeRejectsADeviceReportingNoEfuseMac() async throws {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.connectResult = .success(JadeFixtures.version(.ready, efuseMac: nil))
        let sut = makeManager()

        do {
            try await sut.connectKnownDevice(deviceId: JadeFixtures.deviceId)
            XCTFail("a Jade that cannot prove its identity must be rejected")
        } catch {}

        XCTAssertGreaterThanOrEqual(log.count("service.disconnect"), 1)
        XCTAssertTrue(service.calls.exportTypes.isEmpty)
        XCTAssertNil(sut.connected)
    }

    func testAWrongJadeIsRejectedBeforeThePinPrompt() async throws {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.connectResult = .success(JadeFixtures.version(.locked, efuseMac: "other"))
        let sut = makeManager()

        do {
            try await sut.connectKnownDevice(deviceId: JadeFixtures.deviceId)
            XCTFail("a different Jade must be rejected")
        } catch {}

        XCTAssertTrue(service.calls.unlockNetworks.isEmpty)
        XCTAssertFalse(sut.isUnlocking)
    }

    func testReconnectingAJadeRestoredWithAnotherSeedAddsNoWallet() async throws {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.exportHandler = { _ in JadeFixtures.accountExport(xpub: "zpubOtherSeed") }
        let sut = makeManager()

        do {
            try await sut.connectKnownDevice(deviceId: JadeFixtures.deviceId)
            XCTFail("a wallet the Jade was never paired with must be rejected")
        } catch {}

        XCTAssertTrue(store.saves.isEmpty)
        XCTAssertEqual(store.devices.map(\.walletId), [JadeFixtures.walletId])
        XCTAssertGreaterThanOrEqual(log.count("service.disconnect"), 1)
        XCTAssertNil(sut.connected)
    }

    func testReconnectingAJadeHoldingAnotherPairedWalletLandsOnThatWallet() async throws {
        var otherWallet = JadeFixtures.knownEntry()
        otherWallet.xpubs = ["nativeSegwit": "zpubOtherSeed"]
        otherWallet.walletId = "jade:other-wallet"
        store.devices = [JadeFixtures.knownEntry(), otherWallet]
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.exportHandler = { _ in JadeFixtures.accountExport(xpub: "zpubOtherSeed") }
        let sut = makeManager()

        let connected = try await sut.connectKnownDevice(deviceId: JadeFixtures.deviceId)

        XCTAssertEqual(connected.walletId, "jade:other-wallet")
        XCTAssertEqual(Set(store.devices.map(\.walletId)), [JadeFixtures.walletId, "jade:other-wallet"])
    }

    func testPairingAJadeRestoredWithAnotherSeedAddsItsWallet() async throws {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.exportHandler = { _ in JadeFixtures.accountExport(xpub: "zpubOtherSeed") }
        let sut = makeManager()
        _ = try await sut.scan()

        let connected = try await sut.connect(path: JadeFixtures.blePath)

        XCTAssertNotEqual(connected.walletId, JadeFixtures.walletId)
        XCTAssertEqual(store.devices.count, 2)
    }

    func testCancellingAPendingConnectionClosesTheLinkThenCancelsThenDisconnects() async {
        store.devices = [JadeFixtures.knownEntry()]
        let sut = makeManager()

        await sut.cancelPendingConnection(deviceId: JadeFixtures.deviceId)

        XCTAssertTrue(log.contains("transport.disconnect:\(JadeFixtures.blePath)"))
        XCTAssertEqual(log.entries.filter { $0 == "service.cancel" || $0 == "service.disconnect" }, ["service.cancel", "service.disconnect"])
        XCTAssertNil(sut.connected)
    }

    /// Android closes the link before core. Here both start together, which keeps that guarantee: the
    /// link is released without waiting for core, so a request stuck on the link lets go of core.
    func testClosingAStaleSessionReleasesTheLinkWithoutWaitingForCore() async throws {
        let sut = try await connectedManager()
        let coreGate = service.gate(.disconnect)

        let teardown = Task { await sut.disconnectStaleSession(deviceId: JadeFixtures.deviceId) }
        let linkReleased = await waitUntil { self.log.contains("transport.disconnect.done:\(JadeFixtures.blePath)") }

        XCTAssertTrue(linkReleased, "the link closes while core is still busy")
        XCTAssertFalse(log.contains("service.disconnect.done"))
        XCTAssertNil(sut.connected)
        coreGate.open()
        await teardown.value
        XCTAssertTrue(log.contains("service.disconnect.done"))
    }

    func testATeardownReachesCoreWithoutWaitingForTheLinkToClose() async throws {
        let sut = try await connectedManager()
        let linkGate = transport.gateDisconnects()

        let teardown = Task { await sut.disconnectStaleSession(deviceId: JadeFixtures.deviceId) }
        let coreReached = await waitUntil { self.log.contains("service.disconnect.done") }

        XCTAssertTrue(coreReached, "core hears of the teardown while the link is still closing")
        XCTAssertFalse(log.contains("transport.disconnect.done:\(JadeFixtures.blePath)"))
        linkGate.open()
        await teardown.value
    }

    func testAKnownJadeIsRecognisedByNameAfterItsPathChanged() async throws {
        let readvertised = JadeFixtures.device(path: JadeFixtures.readvertisedPath)
        store.devices = [JadeFixtures.knownEntry(path: JadeFixtures.stalePath)]
        service.stubs.scanned = [readvertised]
        let sut = makeManager()

        let connected = try await sut.connectKnownDevice(deviceId: JadeFixtures.deviceId)

        XCTAssertEqual(connected.path, JadeFixtures.readvertisedPath)
        XCTAssertEqual(service.calls.connectPaths, [JadeFixtures.readvertisedPath])
        let found = try await sut.scan()
        XCTAssertEqual(found, [readvertised])
        XCTAssertTrue(sut.nearbyDevices.isEmpty, "a paired Jade is not offered as new")
    }

    func testPairingDialsThePathAReadvertisedJadeIsScannedUnder() async throws {
        store.devices = [JadeFixtures.knownEntry(path: JadeFixtures.stalePath)]
        service.stubs.scanned = [JadeFixtures.device(path: JadeFixtures.readvertisedPath)]
        let sut = makeManager()

        let connected = try await sut.connect(path: JadeFixtures.stalePath)

        XCTAssertEqual(connected.path, JadeFixtures.readvertisedPath)
        XCTAssertEqual(service.calls.connectPaths, [JadeFixtures.readvertisedPath])
    }

    func testPairingKeepsTheRequestedPathWhenNoScannedJadeAdvertisesAsIt() async throws {
        store.devices = [JadeFixtures.knownEntry(path: JadeFixtures.stalePath)]
        service.stubs.scanned = [JadeFixtures.device(path: JadeFixtures.readvertisedPath, name: "Jade AAAAAA")]
        let sut = makeManager()

        try await sut.connect(path: JadeFixtures.stalePath)

        XCTAssertEqual(service.calls.connectPaths, [JadeFixtures.stalePath])
    }

    func testARebootedJadeIsStillKnownUnderItsNewPath() {
        store.devices = [JadeFixtures.knownEntry(path: JadeFixtures.stalePath)]
        let sut = makeManager()

        XCTAssertTrue(sut.hasKnownDevice(deviceId: JadeFixtures.readvertisedPath, advertisedName: JadeFixtures.advertisedName))
        XCTAssertFalse(sut.hasKnownDevice(deviceId: JadeFixtures.readvertisedPath))
        XCTAssertFalse(sut.hasKnownDevice(deviceId: JadeFixtures.readvertisedPath, advertisedName: "Jade AAAAAA"))
    }

    func testSilentAutoReconnectNeverAsksForThePin() async throws {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.connectResult = .success(JadeFixtures.version(.locked))
        let sut = makeManager()

        let connected = try await sut.autoReconnect()

        XCTAssertTrue(connected.isLocked)
        XCTAssertEqual(connected.walletId, JadeFixtures.walletId)
        XCTAssertTrue(service.calls.unlockNetworks.isEmpty)
        XCTAssertTrue(service.calls.exportTypes.isEmpty)
        XCTAssertFalse(sut.isAutoReconnecting)
        XCTAssertFalse(sut.isConnecting)
    }

    func testEnsureConnectedUnlocksALockedSessionWithoutReconnecting() async throws {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.connectResult = .success(JadeFixtures.version(.locked))
        let sut = makeManager()
        try await sut.autoReconnect()
        service.stubs.isConnected = true

        try await sut.ensureConnected(deviceId: JadeFixtures.deviceId)

        XCTAssertEqual(sut.connected?.isLocked, false)
        XCTAssertEqual(service.calls.unlockNetworks, [.regtest])
        XCTAssertEqual(service.calls.connectPaths.count, 1, "the live session is reused")
    }

    // MARK: - Background (Android cases 19 and 22, case 21 replaced)

    func testABluetoothLinkIsReleasedAfterTheAppStaysInTheBackground() async throws {
        let sut = try await connectedManager(timing: JadeManager.Timing(backgroundRelease: 0.1, expirationMargin: 0.01))

        sut.onAppBackgrounded()
        XCTAssertEqual(backgroundTasks.begun.count, 1)
        sut.onAppBecameActive()
        XCTAssertEqual(backgroundTasks.ended, backgroundTasks.begun)
        try await Task.sleep(for: .seconds(0.3))
        XCTAssertEqual(log.count("service.disconnect"), 0)
        XCTAssertNotNil(sut.connected)

        sut.onAppBackgrounded()
        let released = await waitUntil { self.backgroundTasks.ended.count == 2 }

        XCTAssertTrue(released)
        XCTAssertEqual(backgroundTasks.ended, backgroundTasks.begun)
        XCTAssertEqual(log.count("service.disconnect"), 1)
        XCTAssertTrue(log.contains("transport.disconnect:\(JadeFixtures.blePath)"))
        XCTAssertNil(sut.connected)
    }

    func testRunningOutOfBackgroundTimeReleasesTheLinkImmediately() async throws {
        let sut = try await connectedManager(timing: JadeManager.Timing(backgroundRelease: 60))
        sut.onAppBackgrounded()

        backgroundTasks.expire()

        XCTAssertEqual(log.count("transport.releaseAll"), 1)
        XCTAssertNil(sut.connected)
        XCTAssertFalse(sut.isSessionActive)
        XCTAssertEqual(backgroundTasks.ended, backgroundTasks.begun)
        let coreClosed = await waitUntil { self.log.contains("service.disconnect.done") }
        XCTAssertTrue(coreClosed)
    }

    func testWithoutBackgroundTimeTheLinkIsReleasedAtOnce() async throws {
        let sut = try await connectedManager(timing: JadeManager.Timing(backgroundRelease: 60))
        backgroundTasks.grantsTasks = false

        sut.onAppBackgrounded()
        let released = await waitUntil { self.log.contains("service.disconnect.done") }

        XCTAssertTrue(released)
        XCTAssertNil(sut.connected)
        XCTAssertTrue(backgroundTasks.ended.isEmpty, "an invalid task is never ended")
    }

    func testAutoReconnectRunsAgainAfterABackgroundRelease() async throws {
        let sut = try await connectedManager(timing: Self.fastTiming)
        sut.onAppBackgrounded()
        let released = await waitUntil { self.backgroundTasks.ended.count == 1 }
        XCTAssertTrue(released)
        XCTAssertNil(sut.connected)

        sut.onAppBecameActive()
        sut.startAutoReconnect()
        let reconnected = await waitUntil { sut.connected != nil }

        XCTAssertTrue(reconnected)
        XCTAssertEqual(service.calls.connectPaths.count, 2)
        XCTAssertEqual(sut.connected?.id, JadeFixtures.deviceId)
    }

    func testAPendingReconnectIsCancelledOnBackground() async throws {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        let sut = makeManager(timing: JadeManager.Timing(backgroundRelease: 0.05, expirationMargin: 0, reconnectBackoff: 0.1))
        sut.startAutoReconnect()
        XCTAssertTrue(sut.isSessionActive)

        sut.onAppBackgrounded()

        XCTAssertFalse(sut.isSessionActive)
        XCTAssertEqual(backgroundTasks.begun.count, 1, "a pending reconnect may already have dialled, so a release is still scheduled")
        let released = await waitUntil { self.backgroundTasks.ended.count == 1 }
        XCTAssertTrue(released)
        try await Task.sleep(for: .seconds(0.3))
        XCTAssertTrue(service.calls.connectPaths.isEmpty)
        XCTAssertFalse(log.contains("service.scan"))
    }

    func testForegroundReconnectReadsTheSavedJadeBeforeTheEntriesAreLoaded() async {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.connectResult = .success(JadeFixtures.version(.locked))
        let sut = makeManager(timing: Self.fastTiming)
        XCTAssertTrue(sut.knownDevices.isEmpty)

        sut.startAutoReconnect()
        XCTAssertTrue(sut.isSessionActive)
        let reconnected = await waitUntil { sut.connected != nil }

        XCTAssertTrue(reconnected)
        XCTAssertEqual(sut.connected?.id, JadeFixtures.deviceId)
        XCTAssertTrue(service.calls.unlockNetworks.isEmpty)
    }

    // MARK: - External disconnects (Android cases 23 and 24)

    func testAnExternalDisconnectClearsTheSessionAndTellsCore() async throws {
        let sut = try await connectedManager()

        transport.externalDisconnectSubject.send(JadeFixtures.blePath)
        let notified = await waitUntil { self.service.calls.notifiedPaths == [JadeFixtures.blePath] }

        XCTAssertTrue(notified)
        XCTAssertNil(sut.connected)
    }

    /// Core matches a pending disconnect notice against the connected path, so a notice still in
    /// flight when a reconnect completes would tear the new session down instead of the old one.
    func testAReconnectWaitsForTheDisconnectNoticeToReachCore() async throws {
        let sut = try await connectedManager()
        let notice = service.gate(.notifyDisconnected)
        transport.externalDisconnectSubject.send(JadeFixtures.blePath)
        let notifying = await waitUntil { self.log.contains("service.notifyDisconnected:\(JadeFixtures.blePath)") }
        XCTAssertTrue(notifying)

        let reconnect = Task { try await sut.connectKnownDevice(deviceId: JadeFixtures.deviceId) }
        let scanned = await waitUntil { self.log.count("service.scan") == 2 }
        XCTAssertTrue(scanned)
        try await Task.sleep(for: .seconds(0.1))
        XCTAssertEqual(service.calls.connectPaths.count, 1)

        notice.open()
        _ = try await reconnect.value

        XCTAssertEqual(service.calls.connectPaths.count, 2)
        let noticeDone = try XCTUnwrap(log.entries.firstIndex(of: "service.notifyDisconnected.done"))
        let reconnectStart = try XCTUnwrap(log.entries.lastIndex(of: "service.connect:\(JadeFixtures.blePath)"))
        XCTAssertLessThan(noticeDone, reconnectStart)
    }

    func testAnExternalDisconnectOfAnotherPathIsIgnored() async throws {
        let sut = try await connectedManager()

        sut.handleExternalDisconnect(path: JadeFixtures.stalePath)

        XCTAssertNotNil(sut.connected)
        try await Task.sleep(for: .seconds(0.05))
        XCTAssertTrue(service.calls.notifiedPaths.isEmpty)
    }

    func testAnExternalDisconnectWhileConnectingTellsCore() async throws {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.connectResults = [.failure(JadeError.DeviceDisconnected)]
        let connectGate = service.gate(.connect)
        let sut = makeManager()
        let attempt = Task { try await sut.connectKnownDevice(deviceId: JadeFixtures.deviceId) }
        let dialling = await waitUntil { self.service.calls.connectPaths.count == 1 }
        XCTAssertTrue(dialling)

        sut.handleExternalDisconnect(path: JadeFixtures.blePath)
        let notified = await waitUntil { self.service.calls.notifiedPaths == [JadeFixtures.blePath] }

        XCTAssertTrue(notified)
        connectGate.open()
        _ = try? await attempt.value
        XCTAssertNil(sut.connected)
    }

    // MARK: - Maintenance and device operations (Android cases 25-27)

    func testForgettingTheConnectedJadeClosesItsSessionAndDropsTheEntry() async throws {
        let sut = try await connectedManager()

        await sut.forgetWallet(walletId: JadeFixtures.walletId, pendingName: nil)

        XCTAssertEqual(log.count("service.disconnect"), 1)
        XCTAssertEqual(store.saves.last, [])
        XCTAssertNil(sut.connected)
        XCTAssertTrue(sut.knownDevices.isEmpty)
    }

    func testSignPsbtCompletesTheSignedPsbtIntoATransaction() async throws {
        let sut = makeManager()

        let completed = try await sut.signPsbt("psbt")

        XCTAssertEqual(completed, CompletedTransaction(serializedTx: "rawtx", txid: "txid"))
        XCTAssertEqual(service.calls.signings, ["psbt"])
        XCTAssertEqual(service.calls.finalizations.map(\.original), ["psbt"])
        XCTAssertEqual(service.calls.finalizations.map(\.signed), ["signed"])
    }

    func testVerifyAddressAsksTheDeviceForTheNativeSegwitVariant() async throws {
        let sut = makeManager()

        try await sut.verifyAddress(addressType: .nativeSegwit, derivationPath: "m/84'/1'/0'/0/0", expectedAddress: "bcrt1q")

        XCTAssertEqual(
            service.calls.verifications,
            [.init(network: .regtest, variant: .wpkh, derivationPath: "m/84'/1'/0'/0/0", expectedAddress: "bcrt1q")]
        )
    }

    func testAJadeThatLockedSinceConnectingIsUnlockedAndVerifiesAgain() async throws {
        let sut = try await connectedManager()
        service.stubs.isConnected = true
        service.stubs.verifyErrors = [JadeError.DeviceLocked]

        try await sut.verifyAddress(addressType: .nativeSegwit, derivationPath: "m/84'/1'/0'/0/0", expectedAddress: "bcrt1q")

        XCTAssertEqual(service.calls.verifications.count, 2)
        XCTAssertEqual(service.calls.unlockNetworks, [.regtest])
        XCTAssertEqual(service.calls.connectPaths.count, 1)
        XCTAssertEqual(sut.connected?.isLocked, false)
    }

    func testAJadeThatLockedSinceConnectingIsUnlockedAndSignsAgain() async throws {
        let sut = try await connectedManager()
        service.stubs.isConnected = true
        service.stubs.signErrors = [Bitkit.AppError(error: JadeError.DeviceLocked)]

        let completed = try await sut.signPsbt("psbt")

        XCTAssertEqual(completed.serializedTx, "rawtx")
        XCTAssertEqual(service.calls.signings, ["psbt", "psbt"])
        XCTAssertEqual(service.calls.finalizations.count, 1)
        XCTAssertEqual(service.calls.unlockNetworks, [.regtest])
    }

    func testRenamingAJadeWalletLabelsItsEntries() async throws {
        let sut = try await connectedManager()

        sut.renameWallet(walletId: JadeFixtures.walletId, newName: "  Cold storage  ")

        XCTAssertEqual(store.devices.first?.customLabel, "Cold storage")
        XCTAssertEqual(sut.knownDevices.first?.customLabel, "Cold storage")
    }

    func testPairedPathsArePushedToTheTransport() {
        store.devices = [JadeFixtures.knownEntry()]
        let sut = makeManager()

        sut.loadKnownDevices()

        XCTAssertEqual(transport.pairedPathUpdates.last, [JadeFixtures.blePath])
    }

    // MARK: - Teardown ordering and the connect epoch

    /// Core's disconnect cancels any connect that started before it arrives, so a release still on
    /// its way must be waited out before the next connect dials.
    func testALateReleaseDoesNotCancelTheNextConnect() async throws {
        let sut = try await connectedManager()
        let coreGate = service.gate(.disconnect)
        let release = Task { await sut.releaseSession() }
        let releasing = await waitUntil { self.log.contains("service.disconnect") }
        XCTAssertTrue(releasing)
        XCTAssertNil(sut.connected)
        XCTAssertFalse(sut.isSessionActive)

        let reconnect = Task { try await sut.connectKnownDevice(deviceId: JadeFixtures.deviceId) }
        let scanned = await waitUntil { self.log.count("service.scan") == 2 }
        XCTAssertTrue(scanned)
        try await Task.sleep(for: .seconds(0.1))
        XCTAssertEqual(service.calls.connectPaths.count, 1, "the connect waits for the release to reach core")

        coreGate.open()
        await release.value
        let session = try await reconnect.value

        XCTAssertEqual(sut.connected, session)
        let releaseDone = try XCTUnwrap(log.entries.firstIndex(of: "service.disconnect.done"))
        let reconnectStart = try XCTUnwrap(log.entries.lastIndex(of: "service.connect:\(JadeFixtures.blePath)"))
        XCTAssertLessThan(releaseDone, reconnectStart)
    }

    func testEveryTeardownClearsTheSessionBeforeReachingTheDevice() async throws {
        let teardowns: [(name: String, run: (JadeManager) async -> Void)] = [
            ("disconnect", { await $0.disconnect() }),
            ("disconnectStaleSession", { await $0.disconnectStaleSession(deviceId: JadeFixtures.deviceId) }),
            ("cancelPendingConnection", { await $0.cancelPendingConnection(deviceId: JadeFixtures.deviceId) }),
            ("releaseSession", { await $0.releaseSession() }),
            ("resetForWipe", { await $0.resetForWipe() }),
        ]
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        let sut = makeManager()

        for teardown in teardowns {
            try await sut.connectKnownDevice(deviceId: JadeFixtures.deviceId)
            XCTAssertNotNil(sut.connected, teardown.name)
            let disconnectsBefore = log.count("service.disconnect")
            let coreGate = service.gate(.disconnect)
            let linkGate = transport.gateDisconnects()

            let running = Task { await teardown.run(sut) }
            let reachedCore = await waitUntil { self.log.count("service.disconnect") > disconnectsBefore }

            XCTAssertTrue(reachedCore, teardown.name)
            XCTAssertNil(sut.connected, teardown.name)
            XCTAssertFalse(sut.isSessionActive, teardown.name)
            coreGate.open()
            linkGate.open()
            await running.value
        }
    }

    func testACancelledAttemptUnwindingLateLeavesTheNewerAttemptAlone() async throws {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.connectResults = [
            .failure(JadeError.UserCancelled),
            .success(JadeFixtures.version(.locked)),
        ]
        let connectGate = service.gate(.connect)
        let unlockGate = service.gate(.unlock)
        let sut = makeManager()

        let cancelled = Task { try await sut.connectKnownDevice(deviceId: JadeFixtures.deviceId) }
        let firstDialled = await waitUntil { self.service.calls.connectPaths.count == 1 }
        XCTAssertTrue(firstDialled)
        await sut.cancelPendingConnection(deviceId: JadeFixtures.deviceId)
        let newer = Task { try await sut.connectKnownDevice(deviceId: JadeFixtures.deviceId) }
        let secondDialled = await waitUntil { self.service.calls.connectPaths.count == 2 }
        XCTAssertTrue(secondDialled)
        let teardownsBefore = (log.count("service.disconnect"), log.count("transport.disconnect:\(JadeFixtures.blePath)"))

        connectGate.open()
        do {
            _ = try await cancelled.value
            XCTFail("the cancelled attempt must fail")
        } catch {}

        XCTAssertEqual(log.count("service.disconnect"), teardownsBefore.0, "the cancelled attempt closed nothing")
        XCTAssertEqual(log.count("transport.disconnect:\(JadeFixtures.blePath)"), teardownsBefore.1)
        XCTAssertTrue(sut.isConnecting, "the newer attempt keeps its flag")
        let unlocking = await waitUntil { sut.isUnlocking }
        XCTAssertTrue(unlocking)

        unlockGate.open()
        let session = try await newer.value
        XCTAssertEqual(sut.connected, session)
        XCTAssertFalse(sut.isConnecting)
        XCTAssertFalse(sut.isUnlocking)
    }

    func testNoFlagSticksAfterCancellingAConnect() async throws {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.connectResults = [.failure(JadeError.UserCancelled)]
        let connectGate = service.gate(.connect)
        let sut = makeManager()
        let attempt = Task { try await sut.connectKnownDevice(deviceId: JadeFixtures.deviceId) }
        let dialling = await waitUntil { self.service.calls.connectPaths.count == 1 }
        XCTAssertTrue(dialling)
        XCTAssertTrue(sut.isConnecting)

        await sut.cancelPendingConnection(deviceId: JadeFixtures.deviceId)

        XCTAssertFalse(sut.isConnecting)
        XCTAssertFalse(sut.isSessionActive)
        connectGate.open()
        _ = try? await attempt.value
        XCTAssertFalse(sut.isConnecting)
        try await sut.connectKnownDevice(deviceId: JadeFixtures.deviceId)
        XCTAssertNotNil(sut.connected, "a new connect is not refused as already running")
    }

    func testNoFlagSticksAfterReleasingDuringThePinPrompt() async throws {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.connectResult = .success(JadeFixtures.version(.locked))
        let unlockGate = service.gate(.unlock)
        let sut = makeManager()
        let ensure = Task { try await sut.ensureConnected(deviceId: JadeFixtures.deviceId) }
        let unlocking = await waitUntil { sut.isUnlocking }
        XCTAssertTrue(unlocking)

        await sut.releaseSession()

        XCTAssertFalse(sut.isUnlocking)
        XCTAssertFalse(sut.isConnecting)
        XCTAssertFalse(sut.isSessionActive)
        service.stubs.unlockError = JadeError.UserCancelled
        unlockGate.open()
        _ = try? await ensure.value
        XCTAssertFalse(sut.isUnlocking)
        XCTAssertFalse(sut.isConnecting)
        XCTAssertNil(sut.connected)
    }

    func testNoFlagSticksAfterABackgroundRelease() async throws {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        let connectGate = service.gate(.connect)
        let sut = makeManager(timing: JadeManager.Timing(backgroundRelease: 0.01, expirationMargin: 0, reconnectBackoff: 0.01))
        sut.startAutoReconnect()
        let dialling = await waitUntil { self.service.calls.connectPaths.count == 1 }
        XCTAssertTrue(dialling)
        XCTAssertTrue(sut.isAutoReconnecting)
        XCTAssertTrue(sut.isConnecting)

        sut.onAppBackgrounded()
        let released = await waitUntil { self.backgroundTasks.ended.count == 1 }

        XCTAssertTrue(released)
        XCTAssertTrue(log.contains("service.cancel"))
        XCTAssertFalse(sut.isAutoReconnecting)
        XCTAssertFalse(sut.isConnecting)
        XCTAssertFalse(sut.isSessionActive)
        connectGate.open()
        try await Task.sleep(for: .seconds(0.2))
        XCTAssertNil(sut.connected, "the released attempt does not revive the session")
        XCTAssertFalse(sut.isAutoReconnecting)
        XCTAssertFalse(sut.isConnecting)
        XCTAssertEqual(service.calls.connectPaths.count, 1, "the released reconnect does not retry")
    }

    // MARK: - Reconnect loop and session upkeep

    func testAConnectKnownDeviceIsRefusedWhileAnotherConnectIsRunning() async throws {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        let connectGate = service.gate(.connect)
        let sut = makeManager()
        let first = Task { try await sut.connectKnownDevice(deviceId: JadeFixtures.deviceId) }
        let dialling = await waitUntil { self.service.calls.connectPaths.count == 1 }
        XCTAssertTrue(dialling)

        do {
            try await sut.connectKnownDevice(deviceId: JadeFixtures.deviceId)
            XCTFail("a second connect must be refused")
        } catch {
            XCTAssertEqual((error as? Bitkit.AppError)?.message, "Connection already in progress")
        }

        connectGate.open()
        _ = try await first.value
        XCTAssertEqual(service.calls.connectPaths.count, 1)
    }

    func testIsUnlockingOnlyWhileTheJadeWaitsForItsPin() async throws {
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.connectResult = .success(JadeFixtures.version(.locked))
        let unlockGate = service.gate(.unlock)
        let sut = makeManager()
        _ = try await sut.scan()
        XCTAssertFalse(sut.isUnlocking)

        let pairing = Task { try await sut.connect(path: JadeFixtures.blePath) }
        let unlocking = await waitUntil { sut.isUnlocking }
        XCTAssertTrue(unlocking)
        XCTAssertTrue(sut.isConnecting)

        unlockGate.open()
        _ = try await pairing.value
        XCTAssertFalse(sut.isUnlocking)
        XCTAssertFalse(sut.isConnecting)
    }

    func testReleasingTheSessionCancelsAPendingReconnect() async throws {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        let sut = makeManager(timing: JadeManager.Timing(reconnectBackoff: 0.1))
        sut.startAutoReconnect()
        XCTAssertTrue(sut.isSessionActive)

        await sut.releaseSession()

        XCTAssertFalse(sut.isSessionActive)
        try await Task.sleep(for: .seconds(0.3))
        XCTAssertTrue(service.calls.connectPaths.isEmpty)
    }

    func testEnsureConnectedDropsAPendingReconnectInsteadOfWaitingItOut() async throws {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        let sut = makeManager(timing: JadeManager.Timing(reconnectBackoff: 60))
        sut.startAutoReconnect()
        let started = Date()

        try await sut.ensureConnected(deviceId: JadeFixtures.deviceId)

        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertNotNil(sut.connected)
        XCTAssertEqual(service.calls.connectPaths.count, 1)
    }

    func testPairingCancelsABackgroundReconnectThatIsDialling() async throws {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.connectResults = [.failure(JadeError.UserCancelled)]
        let connectGate = service.gate(.connect)
        let sut = makeManager(timing: JadeManager.Timing(reconnectBackoff: 0.01))
        sut.startAutoReconnect()
        let dialling = await waitUntil { self.service.calls.connectPaths.count == 1 }
        XCTAssertTrue(dialling)

        let pairing = Task { try await sut.connect(path: JadeFixtures.blePath) }
        let cancelled = await waitUntil { self.log.contains("service.cancel") }
        XCTAssertTrue(cancelled)
        connectGate.open()
        let session = try await pairing.value

        XCTAssertEqual(sut.connected, session)
        XCTAssertEqual(service.calls.connectPaths.count, 2)
        let cancelIndex = try XCTUnwrap(log.entries.firstIndex(of: "service.cancel"))
        let pairingStart = try XCTUnwrap(log.entries.lastIndex(of: "service.connect:\(JadeFixtures.blePath)"))
        XCTAssertLessThan(cancelIndex, pairingStart)
    }

    func testACancelledPairingNeverDials() async {
        service.stubs.scanned = [JadeFixtures.device()]
        let sut = makeManager()

        let pairing = Task { try await sut.connect(path: JadeFixtures.blePath) }
        pairing.cancel()

        do {
            _ = try await pairing.value
            XCTFail("a cancelled pairing must not connect")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(service.calls.connectPaths.isEmpty)
        XCTAssertFalse(sut.isConnecting)
    }

    /// Stopping the reconnect in flight can take seconds, and leaving the pairing screen meanwhile
    /// must not dial once it is stopped.
    func testAPairingCancelledWhileStoppingAReconnectNeverDials() async {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.connectResults = [.failure(JadeError.UserCancelled)]
        let connectGate = service.gate(.connect)
        let cancelGate = service.gate(.cancel)
        let sut = makeManager(timing: JadeManager.Timing(reconnectBackoff: 0.01))
        sut.startAutoReconnect()
        let dialling = await waitUntil { self.service.calls.connectPaths.count == 1 }
        XCTAssertTrue(dialling)

        let pairing = Task { try await sut.connect(path: JadeFixtures.blePath) }
        let stopping = await waitUntil { self.log.contains("service.cancel") }
        XCTAssertTrue(stopping)
        pairing.cancel()
        cancelGate.open()
        connectGate.open()

        do {
            _ = try await pairing.value
            XCTFail("a cancelled pairing must not connect")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(service.calls.connectPaths.count, 1, "only the stopped reconnect dialled")
        XCTAssertFalse(sut.isConnecting)
    }

    func testAFailedReconnectAttemptIsRetried() async {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.connectResults = [.failure(JadeError.Timeout), .success(JadeFixtures.version(.locked))]
        let sut = makeManager(timing: Self.fastTiming)

        sut.startAutoReconnect()
        let reconnected = await waitUntil { sut.connected != nil }

        XCTAssertTrue(reconnected)
        XCTAssertEqual(service.calls.connectPaths.count, 2)
        XCTAssertEqual(sut.connected?.id, JadeFixtures.deviceId)
        XCTAssertTrue(service.calls.unlockNetworks.isEmpty)
    }

    /// A busy Jade is waiting on the user, so dialling it again would only interrupt them.
    func testTheReconnectLoopStopsWhenTheJadeIsBusy() async {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.connectResult = .failure(JadeError.DeviceBusy)
        let sut = makeManager(timing: Self.fastTiming)

        sut.startAutoReconnect()
        let stopped = await waitUntil { !sut.isSessionActive }

        XCTAssertTrue(stopped)
        XCTAssertEqual(service.calls.connectPaths.count, 1)
        XCTAssertNil(sut.connected)
    }

    /// A loop cancelled by a release unwinds after the next loop has started, and must not clear it.
    func testACancelledReconnectLoopLeavesTheNewerLoopRunning() async {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        service.stubs.connectResult = .success(JadeFixtures.version(.locked))
        let sut = makeManager(timing: JadeManager.Timing(reconnectBackoff: 0.2))

        sut.startAutoReconnect()
        await sut.releaseSession()
        sut.startAutoReconnect()
        var stayedActive = true
        let dialled = await waitUntil {
            stayedActive = stayedActive && sut.isSessionActive
            return !self.service.calls.connectPaths.isEmpty
        }

        XCTAssertTrue(dialled)
        XCTAssertTrue(stayedActive, "the session stays active until the newer loop dials")
        let reconnected = await waitUntil { sut.connected != nil }
        XCTAssertTrue(reconnected)
        XCTAssertEqual(service.calls.connectPaths.count, 1)
    }

    func testResetForWipeDropsTheSessionAndItsBackgroundWork() async throws {
        let sut = try await connectedManager(timing: JadeManager.Timing(backgroundRelease: 60))
        sut.onAppBackgrounded()
        XCTAssertEqual(backgroundTasks.begun.count, 1)

        await sut.resetForWipe()

        XCTAssertNil(sut.connected)
        XCTAssertTrue(sut.knownDevices.isEmpty)
        XCTAssertFalse(sut.isSessionActive)
        XCTAssertTrue(log.contains("transport.closeAll"))
        XCTAssertEqual(log.count("service.disconnect"), 1)
        XCTAssertEqual(backgroundTasks.ended, backgroundTasks.begun)
        _ = try await sut.scan()
        XCTAssertEqual(log.count("service.initialize"), 2, "a wiped manager sets itself up again")
    }

    // MARK: - App lifecycle without a paired Jade

    /// Starting the Jade Bluetooth central is what shows the iOS Bluetooth prompt, so the calls the app
    /// makes at launch, on scene changes and on a wipe must leave it alone until a Jade is paired.
    func testAppLifecycleWithoutAPairedJadeNeverStartsBluetooth() async {
        let bluetooth = JadeBLEManager()
        let sut = JadeManager(
            service: service,
            transport: JadeTransport(driver: bluetooth, isTrezorBridgeEnabled: { false }),
            store: store,
            backgroundTasks: backgroundTasks,
            timing: JadeManagerTests.fastTiming,
            network: { .regtest }
        )

        sut.loadKnownDevices()
        sut.onAppBecameActive()
        sut.startAutoReconnect()
        sut.onAppBackgrounded()
        sut.onAppBecameActive()
        await sut.resetForWipe()

        XCTAssertFalse(bluetooth.hasCentral)
        XCTAssertFalse(sut.isConnectInProgress)
        XCTAssertTrue(backgroundTasks.begun.isEmpty)
    }

    // MARK: - Helpers

    private func makeManager(timing: JadeManager.Timing = JadeManagerTests.fastTiming) -> JadeManager {
        JadeManager(
            service: service,
            transport: transport,
            store: store,
            backgroundTasks: backgroundTasks,
            timing: timing,
            now: { Date(timeIntervalSince1970: 1000) },
            network: { .regtest }
        )
    }

    /// A manager holding an unlocked session of the paired Jade.
    private func connectedManager(timing: JadeManager.Timing = JadeManagerTests.fastTiming) async throws -> JadeManager {
        store.devices = [JadeFixtures.knownEntry()]
        service.stubs.scanned = [JadeFixtures.device()]
        let sut = makeManager(timing: timing)
        try await sut.connectKnownDevice(deviceId: JadeFixtures.deviceId)
        return sut
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }
}
