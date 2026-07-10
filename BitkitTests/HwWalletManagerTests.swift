@testable import Bitkit
import BitkitCore
import Combine
import XCTest

/// Engine tests for `HwWalletManager`, adapting bitkit-android's `HwWalletRepoTest`.
/// The engine is driven directly (no live `TrezorViewModel`) via `updateDevices` and
/// `handleWatcherEvent`, with spies for the bitkit-core persistence side.
@MainActor
final class HwWalletManagerTests: XCTestCase {
    // MARK: - Mocks & spies

    private final class MockWatcherService: OnChainWatcherServicing, @unchecked Sendable {
        private let lock = NSLock()

        private(set) var startedParams: [WatcherParams] = []
        private(set) var stoppedWatcherIds: [String] = []
        var stopShouldFail = false

        /// When set, keeps the native start call in flight until `completeStart()` resolves it,
        /// mirroring the gate used in `TrezorViewModelWatcherTests`.
        var holdStart = false
        private var startContinuation: CheckedContinuation<Void, Error>?
        private var pendingStartResult: Result<Void, Error>?

        struct StopError: Error {}

        func startWatcher(params: WatcherParams, listener _: EventListener) async throws {
            lock.lock()
            startedParams.append(params)
            let shouldHold = holdStart
            lock.unlock()

            guard shouldHold else { return }
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                defer { lock.unlock() }
                if let result = pendingStartResult {
                    pendingStartResult = nil
                    continuation.resume(with: result)
                } else {
                    startContinuation = continuation
                }
            }
        }

        func completeStart(with result: Result<Void, Error> = .success(())) {
            lock.lock()
            defer { lock.unlock() }
            if let continuation = startContinuation {
                startContinuation = nil
                continuation.resume(with: result)
            } else {
                pendingStartResult = result
            }
        }

        func stopWatcher(watcherId: String) throws {
            lock.lock()
            defer { lock.unlock() }
            stoppedWatcherIds.append(watcherId)
            if stopShouldFail { throw StopError() }
        }

        func stopAllWatchers() {}
    }

    private var persisted: [[Activity]] = []
    private var deleted: [String] = []
    private var receivedTxs: [HwWalletReceivedTx] = []
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        persisted = []
        deleted = []
        receivedTxs = []
        cancellables = []
    }

    // MARK: - Factories

    private func makeViewModel(
        watcherService: OnChainWatcherServicing = MockWatcherService(),
        monitored: Set<String> = ["legacy", "nestedSegwit", "nativeSegwit", "taproot"]
    ) -> HwWalletManager {
        let vm = HwWalletManager(
            watcherService: watcherService,
            monitoredTypes: { monitored },
            electrumUrl: { "ssl://test:1" },
            network: { .regtest },
            persistActivities: { [weak self] in self?.persisted.append($0) },
            deleteActivities: { [weak self] in self?.deleted.append($0) }
        )
        vm.receivedTxPublisher
            .sink { [weak self] in self?.receivedTxs.append($0) }
            .store(in: &cancellables)
        return vm
    }

    private func makeDevice(
        id: String,
        xpubs: [String: String],
        label: String? = nil,
        model: String? = "Safe 5",
        lastConnectedAt: Date = Date(timeIntervalSince1970: 1000)
    ) -> TrezorKnownDevice {
        TrezorKnownDevice(
            id: id,
            name: id,
            path: "ble:\(id)",
            transportType: "bluetooth",
            label: label,
            model: model,
            lastConnectedAt: lastConnectedAt,
            xpubs: xpubs
        )
    }

    /// Build a persistence-ready onchain activity, mirroring what core's watch-only watcher
    /// emits in 0.3.4. `walletId` defaults to empty because the manager re-scopes activities to
    /// the device's derived wallet id before persisting.
    private func makeActivity(
        txId: String,
        value: UInt64,
        txType: PaymentType,
        walletId: String = ""
    ) -> Activity {
        .onchain(OnchainActivity(
            walletId: walletId,
            id: txId,
            txType: txType,
            txId: txId,
            value: value,
            fee: 0,
            feeRate: 1,
            address: "",
            confirmed: true,
            timestamp: 1_700_000_000,
            isBoosted: false,
            boostTxIds: [],
            isTransfer: false,
            doesExist: true,
            confirmTimestamp: 1_700_000_000,
            channelId: nil,
            transferTxId: nil,
            contact: nil,
            createdAt: 1_700_000_000,
            updatedAt: 1_700_000_000,
            seenAt: nil
        ))
    }

    private func makeEvent(_ activities: [Activity], total: UInt64) -> WatcherEvent {
        let balance = WalletBalance(
            confirmed: total, immature: 0, trustedPending: 0, untrustedPending: 0, spendable: total, total: total
        )
        return .transactionsChanged(
            activities: activities,
            transactionDetails: [],
            balance: balance,
            txCount: UInt32(activities.count),
            blockHeight: 100,
            accountType: .nativeSegwit
        )
    }

    private func watcherId(_ deviceId: String, _ addressType: String) -> String {
        "\(deviceId)|\(addressType)"
    }

    // MARK: - Tests

    func testPairedDeviceProducesWalletWithBalanceAndWalletId() throws {
        let xpubs = ["nativeSegwit": "zpubNS"]
        let device = makeDevice(id: "dev1", xpubs: xpubs, model: "Safe 5")
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: "dev1")

        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "tx1", value: 50000, txType: .received)], total: 50000
        ))

        XCTAssertEqual(vm.wallets.count, 1)
        let wallet = vm.wallets[0]
        XCTAssertEqual(wallet.id, "dev1")
        XCTAssertEqual(wallet.balanceSats, 50000)
        XCTAssertEqual(wallet.name, "Trezor Safe 5")
        XCTAssertTrue(wallet.isConnected)
        XCTAssertEqual(vm.totalSats, 50000)
        XCTAssertEqual(wallet.walletId, try HwWalletId.derive(xpubs: xpubs))
        XCTAssertEqual(vm.hwWalletIds, [wallet.walletId])
    }

    func testBalanceAggregatesAcrossAddressTypes() {
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zpubNS", "taproot": "zpubTR"])
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)

        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "txNS", value: 30000, txType: .received)], total: 30000
        ))
        vm.handleWatcherEvent(watcherId: watcherId("dev1", "taproot"), event: makeEvent(
            [makeActivity(txId: "txTR", value: 20000, txType: .received)], total: 20000
        ))

        XCTAssertEqual(vm.wallets.count, 1)
        XCTAssertEqual(vm.wallets[0].balanceSats, 50000)
        XCTAssertFalse(vm.wallets[0].isConnected)
    }

    func testSamePhysicalDeviceDedupedByXpub() {
        // Same xpubs, two device entries (e.g. re-paired) → one wallet, one walletId.
        let xpubs = ["nativeSegwit": "zpubShared"]
        let ble = makeDevice(id: "ble1", xpubs: xpubs, lastConnectedAt: Date(timeIntervalSince1970: 1000))
        let usb = makeDevice(id: "usb1", xpubs: xpubs, lastConnectedAt: Date(timeIntervalSince1970: 2000))
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [ble, usb], connectedDeviceId: nil)

        vm.handleWatcherEvent(watcherId: watcherId("ble1", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "tx1", value: 70000, txType: .received)], total: 70000
        ))

        XCTAssertEqual(vm.wallets.count, 1)
        XCTAssertEqual(vm.wallets[0].deviceIds, ["ble1", "usb1"])
        // Representative is the most recently connected entry.
        XCTAssertEqual(vm.wallets[0].id, "usb1")
        XCTAssertEqual(vm.hwWalletIds.count, 1)
    }

    func testActivityPersistedWithDeviceWalletId() throws {
        let xpubs = ["nativeSegwit": "zpubNS"]
        let device = makeDevice(id: "dev1", xpubs: xpubs)
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: "dev1")

        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "txABC", value: 40000, txType: .received)], total: 40000
        ))

        // The manager re-scopes core's emitted activity to the device's derived wallet id.
        let expectedWalletId = try HwWalletId.derive(xpubs: xpubs)
        XCTAssertEqual(persisted.count, 1)
        let activities = persisted[0]
        XCTAssertEqual(activities.count, 1)
        guard case let .onchain(onchain) = activities[0] else { return XCTFail("expected onchain activity") }
        XCTAssertEqual(onchain.walletId, expectedWalletId)
        XCTAssertEqual(onchain.txId, "txABC")
        XCTAssertEqual(onchain.txType, .received)
        XCTAssertEqual(onchain.value, 40000)
    }

    func testUnchangedWatcherEventDoesNotRepersist() {
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zpubNS"])
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        let wid = watcherId("dev1", "nativeSegwit")
        let event = makeEvent([makeActivity(txId: "tx1", value: 40000, txType: .received)], total: 40000)

        vm.handleWatcherEvent(watcherId: wid, event: event)
        XCTAssertEqual(persisted.count, 1)

        // Identical event again → no re-upsert / no redundant activity-list reload.
        vm.handleWatcherEvent(watcherId: wid, event: event)
        XCTAssertEqual(persisted.count, 1)

        // A changed event (new tx) → persists again.
        let changed = makeEvent([
            makeActivity(txId: "tx1", value: 40000, txType: .received),
            makeActivity(txId: "tx2", value: 10000, txType: .received),
        ], total: 50000)
        vm.handleWatcherEvent(watcherId: wid, event: changed)
        XCTAssertEqual(persisted.count, 2)
    }

    func testReceivedTxDetection() {
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zpubNS"])
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: "dev1")
        let wid = watcherId("dev1", "nativeSegwit")

        // Baseline (first event) — must NOT emit, even for received txs.
        vm.handleWatcherEvent(watcherId: wid, event: makeEvent(
            [makeActivity(txId: "old", value: 10000, txType: .received)], total: 10000
        ))
        XCTAssertTrue(receivedTxs.isEmpty)

        // New inbound tx after baseline — emits once.
        vm.handleWatcherEvent(watcherId: wid, event: makeEvent(
            [
                makeActivity(txId: "old", value: 10000, txType: .received),
                makeActivity(txId: "new", value: 25000, txType: .received),
            ], total: 35000
        ))
        XCTAssertEqual(receivedTxs.map(\.txid), ["new"])
        XCTAssertEqual(receivedTxs.first?.sats, 25000)

        // Outbound tx is ignored, and the same inbound is not re-emitted.
        vm.handleWatcherEvent(watcherId: wid, event: makeEvent(
            [
                makeActivity(txId: "old", value: 10000, txType: .received),
                makeActivity(txId: "new", value: 25000, txType: .received),
                makeActivity(txId: "spend", value: 5000, txType: .sent),
            ], total: 30000
        ))
        XCTAssertEqual(receivedTxs.map(\.txid), ["new"])
    }

    func testMonitoredAddressTypeFiltering() async {
        let mock = MockWatcherService()
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zpubNS", "taproot": "zpubTR"])
        let vm = makeViewModel(watcherService: mock, monitored: ["nativeSegwit"])
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)

        await waitUntil { mock.startedParams.count == 1 }
        XCTAssertEqual(mock.startedParams.count, 1)
        XCTAssertEqual(mock.startedParams.first?.watcherId, watcherId("dev1", "nativeSegwit"))
    }

    func testForgottenDeviceDuringInFlightStartIsTornDownNotActivated() async {
        let mock = MockWatcherService()
        mock.holdStart = true
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zpubNS"])
        let vm = makeViewModel(watcherService: mock, monitored: ["nativeSegwit"])
        let wid = watcherId("dev1", "nativeSegwit")

        vm.updateDevices(knownDevices: [device], connectedDeviceId: "dev1")
        await waitUntil { mock.startedParams.count == 1 }

        // Forget the device while its watcher start is still in flight.
        vm.updateDevices(knownDevices: [], connectedDeviceId: nil)

        // Resolving the now-undesired start must tear the watcher down, not activate it.
        mock.completeStart()
        await waitUntil { mock.stoppedWatcherIds.contains(wid) }

        XCTAssertTrue(mock.stoppedWatcherIds.contains(wid))
        XCTAssertTrue(vm.wallets.isEmpty)
        XCTAssertEqual(vm.totalSats, 0)
    }

    func testZeroBalanceBeforeAnyWatcherEvent() {
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zpubNS"])
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)

        XCTAssertEqual(vm.wallets.count, 1)
        XCTAssertEqual(vm.wallets[0].balanceSats, 0)
        XCTAssertEqual(vm.totalSats, 0)
        XCTAssertTrue(vm.walletsLoaded)
    }

    func testNoWalletWithoutCapturedXpubs() {
        let device = makeDevice(id: "dev1", xpubs: [:])
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)

        XCTAssertTrue(vm.wallets.isEmpty)
        XCTAssertTrue(vm.hwWalletIds.isEmpty)
    }

    func testDisplayNameUsesDeviceLabelWhenSet() {
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "x"], label: "My Trezor", model: "Safe 5")
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        XCTAssertEqual(vm.wallets.first?.name, "My Trezor")
    }

    func testDisplayNameUsesVendorPrefixedModelWhenLabelMissing() {
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "x"], label: nil, model: "Safe 7")
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        XCTAssertEqual(vm.wallets.first?.name, "Trezor Safe 7")
    }

    func testDisplayNameUsesVendorPrefixWhenLabelIsFactoryDefault() {
        // Factory label mirrors the model — fall back to the vendor-prefixed model.
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "x"], label: "Safe 7", model: "Safe 7")
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        XCTAssertEqual(vm.wallets.first?.name, "Trezor Safe 7")
    }

    func testDisplayNameKeepsModelAlreadyPrefixed() {
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "x"], label: nil, model: "Trezor Model T")
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        XCTAssertEqual(vm.wallets.first?.name, "Trezor Model T")
    }

    func testDisplayNameDefaultsToTrezorWhenNoModel() {
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "x"], label: nil, model: nil)
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        XCTAssertEqual(vm.wallets.first?.name, "Trezor")
    }

    /// The same tx seen by two address-type watchers persists once (deduped by activity id).
    /// Value composition is core's job now (core 0.3.4 watch-only watcher), so this only checks
    /// dedup, not summing.
    func testDuplicateTxAcrossAddressTypesPersistsOnce() {
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zNS", "taproot": "zTR"])
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)

        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "shared", value: 30000, txType: .received)], total: 30000
        ))
        vm.handleWatcherEvent(watcherId: watcherId("dev1", "taproot"), event: makeEvent(
            [makeActivity(txId: "shared", value: 30000, txType: .received)], total: 30000
        ))

        let lastPersisted = persisted.last ?? []
        XCTAssertEqual(lastPersisted.count, 1)
        guard case let .onchain(onchain) = lastPersisted[0] else { return XCTFail("expected onchain") }
        XCTAssertEqual(onchain.txId, "shared")
    }

    func testMixedDirectionDuplicateResolvesDeterministically() {
        /// The same txid seen by two address-type watchers can carry different wallet-perspective
        /// directions; the merge must resolve to the same winner regardless of arrival order.
        func mergedTxType(nativeSegwitFirst: Bool) -> PaymentType? {
            persisted = []
            let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zNS", "taproot": "zTR"])
            let vm = makeViewModel()
            vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
            let ns = watcherId("dev1", "nativeSegwit")
            let tr = watcherId("dev1", "taproot")
            let nsEvent = makeEvent([makeActivity(txId: "shared", value: 5000, txType: .sent)], total: 5000)
            let trEvent = makeEvent([makeActivity(txId: "shared", value: 30000, txType: .received)], total: 30000)
            if nativeSegwitFirst {
                vm.handleWatcherEvent(watcherId: ns, event: nsEvent)
                vm.handleWatcherEvent(watcherId: tr, event: trEvent)
            } else {
                vm.handleWatcherEvent(watcherId: tr, event: trEvent)
                vm.handleWatcherEvent(watcherId: ns, event: nsEvent)
            }
            let shared = (persisted.last ?? []).first {
                if case let .onchain(onchain) = $0 { return onchain.txId == "shared" }
                return false
            }
            guard case let .onchain(onchain) = shared else { return nil }
            return onchain.txType
        }

        let nsFirst = mergedTxType(nativeSegwitFirst: true)
        let trFirst = mergedTxType(nativeSegwitFirst: false)

        XCTAssertEqual(nsFirst, trFirst)
        // 'dev1|taproot' sorts after 'dev1|nativeSegwit', so the taproot perspective wins.
        XCTAssertEqual(nsFirst, .received)
    }

    func testWatcherStartedOnConfiguredElectrumAndNetwork() async {
        let mock = MockWatcherService()
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "z"])
        let vm = makeViewModel(watcherService: mock, monitored: ["nativeSegwit"])
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)

        await waitUntil { mock.startedParams.count == 1 }
        let params = mock.startedParams.first
        XCTAssertEqual(params?.electrumUrl, "ssl://test:1")
        XCTAssertEqual(params?.network, .regtest)
        XCTAssertEqual(params?.extendedKey, "z")
        XCTAssertEqual(params?.accountType, .nativeSegwit)
    }

    func testWatcherRestartsWhenXpubChangesForSameDeviceAndType() async {
        let mock = MockWatcherService()
        let vm = makeViewModel(watcherService: mock, monitored: ["nativeSegwit"])
        vm.updateDevices(knownDevices: [makeDevice(id: "dev1", xpubs: ["nativeSegwit": "z"])], connectedDeviceId: nil)
        await waitUntil { mock.startedParams.count == 1 }
        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "t1", value: 40000, txType: .received)], total: 40000
        ))
        let originalWalletId = vm.wallets.first?.walletId

        // Same device id + address type, new xpub (e.g. a passphrase/hidden wallet, or re-fetched
        // accounts): the watcher id is unchanged but the watched key — and the derived wallet id —
        // differ, so the old watcher must be torn down and a new one started on the new xpub
        // instead of feeding the old wallet's balance under the new wallet id.
        vm.updateDevices(knownDevices: [makeDevice(id: "dev1", xpubs: ["nativeSegwit": "z2"])], connectedDeviceId: nil)
        await waitUntil { mock.startedParams.count == 2 }

        XCTAssertTrue(mock.stoppedWatcherIds.contains(watcherId("dev1", "nativeSegwit")))
        XCTAssertEqual(mock.startedParams.last?.extendedKey, "z2")
        XCTAssertNotEqual(vm.wallets.first?.walletId, originalWalletId)
        XCTAssertEqual(vm.wallets.first?.balanceSats, 0, "stale old-xpub balance is dropped until the new watcher reports")
    }

    func testReconcileForSettingsChangeSkipsUnchangedAndActsOnChange() async {
        let mock = MockWatcherService()
        var monitored: Set = ["nativeSegwit"]
        let electrum = "ssl://a:1"
        var electrumCalls = 0
        let vm = HwWalletManager(
            watcherService: mock,
            monitoredTypes: { monitored },
            electrumUrl: { electrumCalls += 1; return electrum },
            network: { .regtest },
            persistActivities: { _ in },
            deleteActivities: { _ in }
        )
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zNS", "taproot": "zTR"])
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        await waitUntil { mock.startedParams.count == 1 }

        // Prime the last-synced snapshot.
        vm.reconcileForSettingsChange()

        // Unchanged settings: the guard short-circuits before syncWatchers, so the Electrum
        // provider is read exactly once (the guard) and no watcher work happens.
        electrumCalls = 0
        vm.reconcileForSettingsChange()
        XCTAssertEqual(electrumCalls, 1)
        XCTAssertEqual(mock.startedParams.count, 1)

        // A monitored-types change does reconcile: the taproot watcher starts.
        monitored = ["nativeSegwit", "taproot"]
        vm.reconcileForSettingsChange()
        await waitUntil { mock.startedParams.count == 2 }
        XCTAssertEqual(mock.startedParams.count, 2)
    }

    func testDisablingAddressTypeClearsBalanceImmediately() async {
        let mock = MockWatcherService()
        var monitored: Set = ["nativeSegwit"]
        let vm = HwWalletManager(
            watcherService: mock,
            monitoredTypes: { monitored },
            electrumUrl: { "ssl://test:1" },
            network: { .regtest },
            persistActivities: { _ in },
            deleteActivities: { _ in }
        )
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zNS"])
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        await waitUntil { mock.startedParams.count == 1 }

        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "tx1", value: 50000, txType: .received)], total: 50000
        ))
        XCTAssertEqual(vm.totalSats, 50000)

        // Disabling the only monitored address type stops the watcher; the published totals must
        // drop immediately, without waiting for any further watcher event.
        monitored = []
        vm.reconcileForSettingsChange()

        XCTAssertEqual(vm.totalSats, 0)
        XCTAssertEqual(vm.wallets.first?.balanceSats, 0)
    }

    func testReceivedTxEmittedOnceAcrossMultipleWatchers() {
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zNS", "taproot": "zTR"])
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        let ns = watcherId("dev1", "nativeSegwit")
        let tr = watcherId("dev1", "taproot")

        // Baselines for both watchers.
        vm.handleWatcherEvent(watcherId: ns, event: makeEvent([], total: 0))
        vm.handleWatcherEvent(watcherId: tr, event: makeEvent([], total: 0))

        // Both watchers report the same new inbound tx — emit only once.
        let tx = makeActivity(txId: "new", value: 10000, txType: .received)
        vm.handleWatcherEvent(watcherId: ns, event: makeEvent([tx], total: 10000))
        vm.handleWatcherEvent(watcherId: tr, event: makeEvent([tx], total: 10000))

        XCTAssertEqual(receivedTxs.map(\.txid), ["new"])
    }

    func testConnectedEntryWinsRepresentativeIdentity() {
        // Same xpub over two entries; the more recent is `ble1`, but `usb1` is connected.
        let xpubs = ["nativeSegwit": "shared"]
        let ble = makeDevice(id: "ble1", xpubs: xpubs, lastConnectedAt: Date(timeIntervalSince1970: 2000))
        let usb = makeDevice(id: "usb1", xpubs: xpubs, lastConnectedAt: Date(timeIntervalSince1970: 1000))
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [ble, usb], connectedDeviceId: "usb1")

        XCTAssertEqual(vm.wallets.count, 1)
        XCTAssertEqual(vm.wallets[0].id, "usb1")
        XCTAssertTrue(vm.wallets[0].isConnected)
    }

    func testTotalSatsSaturatesInsteadOfOverflowing() {
        let d1 = makeDevice(id: "d1", xpubs: ["nativeSegwit": "a"])
        let d2 = makeDevice(id: "d2", xpubs: ["nativeSegwit": "b"])
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [d1, d2], connectedDeviceId: nil)

        // Per-device balance comes from the watcher's reported total; d1 maxes it out.
        vm.handleWatcherEvent(watcherId: watcherId("d1", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "t1", value: 1000, txType: .received)], total: .max
        ))
        vm.handleWatcherEvent(watcherId: watcherId("d2", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "t2", value: 1000, txType: .received)], total: 1000
        ))

        XCTAssertEqual(vm.totalSats, .max)
    }

    func testStaleWatcherKeptUntilStopSucceeds() async {
        let mock = MockWatcherService()
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "z"])
        let vm = makeViewModel(watcherService: mock, monitored: ["nativeSegwit"])
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        await waitUntil { mock.startedParams.count == 1 }

        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "t1", value: 40000, txType: .received)], total: 40000
        ))
        XCTAssertEqual(vm.wallets.first?.balanceSats, 40000)

        // Stop fails → the watcher must stay active and keep feeding its balance.
        mock.stopShouldFail = true
        vm.updateDevices(knownDevices: [makeDevice(id: "dev1", xpubs: [:])], connectedDeviceId: nil)
        XCTAssertTrue(mock.stoppedWatcherIds.contains(watcherId("dev1", "nativeSegwit")))

        // Stop now succeeds → next sync removes it.
        mock.stopShouldFail = false
        vm.updateDevices(knownDevices: [makeDevice(id: "dev1", xpubs: [:])], connectedDeviceId: nil)
        XCTAssertTrue(vm.wallets.isEmpty)
    }

    func testRemoveDeviceStopsWatchersAndDeletesActivities() async throws {
        let mock = MockWatcherService()
        let xpubs = ["nativeSegwit": "z"]
        let device = makeDevice(id: "dev1", xpubs: xpubs)
        let vm = makeViewModel(watcherService: mock, monitored: ["nativeSegwit"])
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        await waitUntil { mock.startedParams.count == 1 }
        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "t1", value: 1000, txType: .received)], total: 1000
        ))

        vm.removeDevice(id: "dev1")

        XCTAssertTrue(mock.stoppedWatcherIds.contains(watcherId("dev1", "nativeSegwit")))
        XCTAssertEqual(deleted, try [HwWalletId.derive(xpubs: xpubs)])
    }

    func testRemoveWalletForgetsEveryDeviceEntry() async throws {
        let xpubs = ["nativeSegwit": "z"]
        let devices = [
            makeDevice(id: "dev1", xpubs: xpubs),
            makeDevice(id: "dev2", xpubs: xpubs),
        ]
        let vm = makeViewModel(monitored: ["nativeSegwit"])
        vm.updateDevices(knownDevices: devices, connectedDeviceId: nil)
        let wallet = try XCTUnwrap(vm.wallets.first)
        var forgottenDeviceIds: [String] = []

        await vm.removeWallet(wallet) { forgottenDeviceIds.append($0) }

        XCTAssertEqual(Set(forgottenDeviceIds), wallet.deviceIds)
        XCTAssertEqual(deleted, try [HwWalletId.derive(xpubs: xpubs)])
    }

    // MARK: - Forget device deletes activities

    func testForgettingDeviceViaUpdateDeletesActivities() async throws {
        let mock = MockWatcherService()
        let xpubs = ["nativeSegwit": "z"]
        let device = makeDevice(id: "dev1", xpubs: xpubs)
        let vm = makeViewModel(watcherService: mock, monitored: ["nativeSegwit"])
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        await waitUntil { mock.startedParams.count == 1 }
        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "t1", value: 1000, txType: .received)], total: 1000
        ))
        let walletId = try HwWalletId.derive(xpubs: xpubs)

        // Device forgotten → the next snapshot no longer includes it.
        vm.updateDevices(knownDevices: [], connectedDeviceId: nil)

        XCTAssertEqual(deleted, [walletId])
        XCTAssertTrue(vm.wallets.isEmpty)
        XCTAssertTrue(mock.stoppedWatcherIds.contains(watcherId("dev1", "nativeSegwit")))
    }

    func testUpdateKeepingDeviceDoesNotDeleteActivities() async {
        let mock = MockWatcherService()
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "z"])
        let vm = makeViewModel(watcherService: mock, monitored: ["nativeSegwit"])
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        await waitUntil { mock.startedParams.count == 1 }

        // Same device pushed again (e.g. connection toggled) → no deletion.
        vm.updateDevices(knownDevices: [device], connectedDeviceId: "dev1")

        XCTAssertTrue(deleted.isEmpty)
        XCTAssertEqual(vm.wallets.count, 1)
    }

    // MARK: - Fix 7: watcher start-race guard

    func testDoubleSyncDoesNotDoubleStartWatcher() async {
        let mock = MockWatcherService()
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "z"])
        let vm = makeViewModel(watcherService: mock, monitored: ["nativeSegwit"])

        // Two pushes back-to-back, before the first start's async Task can complete.
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)

        await waitUntil { mock.startedParams.count >= 1 }
        // Give any erroneous second start a chance to land before asserting.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(mock.startedParams.count, 1)
    }

    // MARK: - Helpers

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
