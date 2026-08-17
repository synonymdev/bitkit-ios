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

        /// Watcher ids whose native start always fails, so the manager retries them and they never
        /// report — the "watcher that can't start" case the completeness gate has to tolerate.
        var startFailures: Set<String> = []
        private var startContinuation: CheckedContinuation<Void, Error>?
        private var pendingStartResult: Result<Void, Error>?

        struct StopError: Error {}
        struct StartError: Error {}

        func startWatcher(params: WatcherParams, listener _: EventListener) async throws {
            lock.lock()
            startedParams.append(params)
            let shouldFail = startFailures.contains(params.watcherId)
            let shouldHold = holdStart
            lock.unlock()

            if shouldFail { throw StartError() }
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

    private var persistedSnapshots: [HwWalletSnapshot] = []
    private var deleted: [String] = []
    private var receivedTxs: [HwWalletReceivedTx] = []
    private var cancellables: Set<AnyCancellable> = []

    /// The activity sets handed to core, oldest first — most assertions only care about these.
    private var persisted: [[Activity]] {
        persistedSnapshots.map(\.activities)
    }

    override func setUp() {
        super.setUp()
        persistedSnapshots = []
        deleted = []
        receivedTxs = []
        cancellables = []
        xpubsByDeviceId = [:]
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
            persistSnapshot: { [weak self] in self?.persistedSnapshots.append($0) },
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
        xpubsByDeviceId[id] = xpubs
        return TrezorKnownDevice(
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

    /// Mirrors the unconfirmed rows core emits while a transaction sits in the mempool: the
    /// timestamp advances on every poll even though nothing about the transaction changed.
    private func makeUnconfirmedActivity(txId: String, value: UInt64, timestamp: UInt64) -> Activity {
        guard case var .onchain(onchain) = makeActivity(txId: txId, value: value, txType: .received) else {
            fatalError("makeActivity must produce an onchain activity")
        }
        onchain.confirmed = false
        onchain.confirmTimestamp = nil
        onchain.timestamp = timestamp
        return .onchain(onchain)
    }

    private func makeTransactionDetails(txId: String, walletId: String = "") -> TransactionDetails {
        TransactionDetails(
            walletId: walletId,
            txId: txId,
            amountSats: 50000,
            inputs: [TxInput(txid: "prev-\(txId)", vout: 0, scriptsig: "", witness: [], sequence: 0)],
            outputs: [TxOutput(
                scriptpubkey: "",
                scriptpubkeyType: "v0_p2wpkh",
                scriptpubkeyAddress: "bcrt1qout-\(txId)",
                value: 50000,
                n: 0
            )]
        )
    }

    private func makeEvent(
        _ activities: [Activity],
        total: UInt64,
        transactionDetails: [TransactionDetails] = []
    ) -> WatcherEvent {
        let balance = WalletBalance(
            confirmed: total, immature: 0, trustedPending: 0, untrustedPending: 0, spendable: total, total: total
        )
        return .transactionsChanged(
            activities: activities,
            transactionDetails: transactionDetails,
            balance: balance,
            txCount: UInt32(activities.count),
            blockHeight: 100,
            accountType: .nativeSegwit
        )
    }

    /// Watcher ids are keyed by wallet identity, so they are derived from the device's xpubs.
    /// `makeDevice` records them here so tests can keep naming devices by their transport id.
    private var xpubsByDeviceId: [String: [String: String]] = [:]

    private func watcherId(_ deviceId: String, _ addressType: String) -> String {
        let derived = (try? HwWalletId.derive(xpubs: xpubsByDeviceId[deviceId] ?? [:])) ?? deviceId
        return "\(derived)|\(addressType)"
    }

    /// Needed when one device id holds several identities, where the registry above can only
    /// remember the last one written for it.
    private func watcherId(_ device: TrezorKnownDevice, _ addressType: String) -> String {
        let derived = (try? HwWalletId.derive(xpubs: device.xpubs)) ?? device.id
        return "\(derived)|\(addressType)"
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
        XCTAssertEqual(wallet.id, wallet.walletId, "a wallet is identified by its wallet id, not by its transport")
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
        let ble = makeDevice(id: "ble1", xpubs: xpubs, label: "Older", lastConnectedAt: Date(timeIntervalSince1970: 1000))
        let usb = makeDevice(id: "usb1", xpubs: xpubs, label: "Newer", lastConnectedAt: Date(timeIntervalSince1970: 2000))
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [ble, usb], connectedDeviceId: nil)

        vm.handleWatcherEvent(watcherId: watcherId("ble1", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "tx1", value: 70000, txType: .received)], total: 70000
        ))

        XCTAssertEqual(vm.wallets.count, 1)
        XCTAssertEqual(vm.wallets[0].deviceIds, ["ble1", "usb1"])
        XCTAssertEqual(vm.wallets[0].balanceSats, 70000, "one watcher feeds the single identity")
        // The entries share an identity, so the most recently connected one names it.
        XCTAssertEqual(vm.wallets[0].name, "Newer")
        XCTAssertEqual(vm.hwWalletIds.count, 1)
    }

    func testActivityPersistedWithDeviceWalletId() async throws {
        let xpubs = ["nativeSegwit": "zpubNS"]
        let device = makeDevice(id: "dev1", xpubs: xpubs)
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: "dev1")

        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "txABC", value: 40000, txType: .received)], total: 40000
        ))

        // The manager re-scopes core's emitted activity to the device's derived wallet id.
        let expectedWalletId = try HwWalletId.derive(xpubs: xpubs)
        await vm.drainPendingPersists()
        XCTAssertEqual(persisted.count, 1)
        let activities = persisted[0]
        XCTAssertEqual(activities.count, 1)
        guard case let .onchain(onchain) = activities[0] else { return XCTFail("expected onchain activity") }
        XCTAssertEqual(onchain.walletId, expectedWalletId)
        XCTAssertEqual(onchain.txId, "txABC")
        XCTAssertEqual(onchain.txType, .received)
        XCTAssertEqual(onchain.value, 40000)
    }

    func testTransactionDetailsPersistedScopedToDeviceWalletId() async throws {
        let xpubs = ["nativeSegwit": "zpubNS"]
        let device = makeDevice(id: "dev1", xpubs: xpubs)
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: "dev1")

        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "txABC", value: 50000, txType: .received)],
            total: 50000,
            transactionDetails: [makeTransactionDetails(txId: "txABC")]
        ))

        // Without these, Explore has no inputs/outputs to show for a hardware row.
        let expectedWalletId = try HwWalletId.derive(xpubs: xpubs)
        await vm.drainPendingPersists()
        XCTAssertEqual(persistedSnapshots.count, 1)
        XCTAssertEqual(persistedSnapshots[0].walletId, expectedWalletId)
        XCTAssertEqual(persistedSnapshots[0].transactionDetails.map(\.txId), ["txABC"])
        XCTAssertEqual(persistedSnapshots[0].transactionDetails.map(\.walletId), [expectedWalletId])
    }

    func testTransactionDetailsDedupedAcrossAddressTypeWatchers() async {
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zNS", "taproot": "zTR"])
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        let shared = makeActivity(txId: "shared", value: 50000, txType: .received)
        let details = makeTransactionDetails(txId: "shared")

        vm.handleWatcherEvent(
            watcherId: watcherId("dev1", "nativeSegwit"),
            event: makeEvent([shared], total: 50000, transactionDetails: [details])
        )
        vm.handleWatcherEvent(
            watcherId: watcherId("dev1", "taproot"),
            event: makeEvent([shared], total: 50000, transactionDetails: [details])
        )

        await vm.drainPendingPersists()
        XCTAssertEqual(persistedSnapshots.last?.transactionDetails.map(\.txId), ["shared"])
    }

    func testMempoolTimestampDriftDoesNotRepersist() async {
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zpubNS"])
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        let wid = watcherId("dev1", "nativeSegwit")

        vm.handleWatcherEvent(watcherId: wid, event: makeEvent(
            [makeUnconfirmedActivity(txId: "tx1", value: 40000, timestamp: 1_700_000_000)], total: 40000
        ))
        await vm.drainPendingPersists()
        XCTAssertEqual(persistedSnapshots.count, 1)

        // Same mempool transaction, later poll: only the timestamp moved, so nothing is re-written.
        vm.handleWatcherEvent(watcherId: wid, event: makeEvent(
            [makeUnconfirmedActivity(txId: "tx1", value: 40000, timestamp: 1_700_000_030)], total: 40000
        ))
        await vm.drainPendingPersists()
        XCTAssertEqual(persistedSnapshots.count, 1)

        // Confirmation is a real change, so it persists.
        vm.handleWatcherEvent(watcherId: wid, event: makeEvent(
            [makeActivity(txId: "tx1", value: 40000, txType: .received)], total: 40000
        ))
        await vm.drainPendingPersists()
        XCTAssertEqual(persistedSnapshots.count, 2)
    }

    func testUnchangedWatcherEventDoesNotRepersist() async {
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zpubNS"])
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        let wid = watcherId("dev1", "nativeSegwit")
        let event = makeEvent([makeActivity(txId: "tx1", value: 40000, txType: .received)], total: 40000)

        vm.handleWatcherEvent(watcherId: wid, event: event)
        await vm.drainPendingPersists()
        XCTAssertEqual(persisted.count, 1)

        // Identical event again → no re-upsert / no redundant activity-list reload.
        vm.handleWatcherEvent(watcherId: wid, event: event)
        await vm.drainPendingPersists()
        XCTAssertEqual(persisted.count, 1)

        // A changed event (new tx) → persists again.
        let changed = makeEvent([
            makeActivity(txId: "tx1", value: 40000, txType: .received),
            makeActivity(txId: "tx2", value: 10000, txType: .received),
        ], total: 50000)
        vm.handleWatcherEvent(watcherId: wid, event: changed)
        await vm.drainPendingPersists()
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
    func testDuplicateTxAcrossAddressTypesPersistsOnce() async {
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zNS", "taproot": "zTR"])
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)

        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "shared", value: 30000, txType: .received)], total: 30000
        ))
        vm.handleWatcherEvent(watcherId: watcherId("dev1", "taproot"), event: makeEvent(
            [makeActivity(txId: "shared", value: 30000, txType: .received)], total: 30000
        ))

        await vm.drainPendingPersists()
        let lastPersisted = persisted.last ?? []
        XCTAssertEqual(lastPersisted.count, 1)
        guard case let .onchain(onchain) = lastPersisted[0] else { return XCTFail("expected onchain") }
        XCTAssertEqual(onchain.txId, "shared")
    }

    func testMixedDirectionDuplicateResolvesDeterministically() async {
        /// The same txid seen by two address-type watchers can carry different wallet-perspective
        /// directions; the merge must resolve to the same winner regardless of arrival order.
        func mergedTxType(nativeSegwitFirst: Bool) async -> PaymentType? {
            persistedSnapshots = []
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
            await vm.drainPendingPersists()
            let shared = (persisted.last ?? []).first {
                if case let .onchain(onchain) = $0 { return onchain.txId == "shared" }
                return false
            }
            guard case let .onchain(onchain) = shared else { return nil }
            return onchain.txType
        }

        let nsFirst = await mergedTxType(nativeSegwitFirst: true)
        let trFirst = await mergedTxType(nativeSegwitFirst: false)

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

    func testWatcherMovesToTheNewIdWhenTheWalletIdChanges() async {
        let mock = MockWatcherService()
        let original = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "z"])
        let vm = makeViewModel(watcherService: mock, monitored: ["nativeSegwit"])
        vm.updateDevices(knownDevices: [original], connectedDeviceId: nil)
        await waitUntil { mock.startedParams.count == 1 }
        vm.handleWatcherEvent(watcherId: watcherId(original, "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "t1", value: 40000, txType: .received)], total: 40000
        ))
        let originalWalletId = vm.wallets.first?.walletId

        // Same device id + address type, new xpub (e.g. re-fetched accounts): the wallet id derives
        // from the key material, so this is a different identity and a different watcher id. The old
        // watcher must be torn down rather than left feeding the old balance under the new identity.
        let rekeyed = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "z2"])
        vm.updateDevices(knownDevices: [rekeyed], connectedDeviceId: nil)
        await waitUntil { mock.startedParams.count == 2 }

        XCTAssertTrue(mock.stoppedWatcherIds.contains(watcherId(original, "nativeSegwit")))
        XCTAssertEqual(mock.startedParams.last?.watcherId, watcherId(rekeyed, "nativeSegwit"))
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
            persistSnapshot: { _ in },
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
            persistSnapshot: { _ in },
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
        let ble = makeDevice(id: "ble1", xpubs: xpubs, label: "Ble", lastConnectedAt: Date(timeIntervalSince1970: 2000))
        let usb = makeDevice(id: "usb1", xpubs: xpubs, label: "Usb", lastConnectedAt: Date(timeIntervalSince1970: 1000))
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [ble, usb], connectedDeviceId: "usb1")

        XCTAssertEqual(vm.wallets.count, 1)
        XCTAssertEqual(vm.wallets[0].name, "Usb", "the connected entry names the wallet")
        XCTAssertTrue(vm.wallets[0].isConnected)
    }

    // MARK: - Several wallet identities on one device

    func testPassphraseWalletIsWatchedNextToTheStandardWalletOfTheSameDevice() {
        let standard = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zStandard"])
        let hidden = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zHidden"])
        let vm = makeViewModel(monitored: ["nativeSegwit"])
        vm.updateDevices(knownDevices: [standard, hidden], connectedDeviceId: "dev1")

        vm.handleWatcherEvent(watcherId: watcherId(standard, "nativeSegwit"), event: makeEvent([], total: 30000))
        vm.handleWatcherEvent(watcherId: watcherId(hidden, "nativeSegwit"), event: makeEvent([], total: 20000))

        XCTAssertEqual(vm.wallets.count, 2, "one tile per identity, not per device")
        XCTAssertEqual(vm.wallets.map(\.balanceSats), [30000, 20000], "each identity counts its own balance")
        XCTAssertEqual(vm.totalSats, 50000)
        XCTAssertEqual(vm.hwWalletIds.count, 2)
    }

    /// A device only holds one wallet open at a time, and only that identity can sign.
    func testOnlyTheIdentityHoldingTheSessionShowsAsConnected() throws {
        let standard = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zStandard"])
        let hidden = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zHidden"])
        let hiddenWalletId = try HwWalletId.derive(xpubs: hidden.xpubs)
        let vm = makeViewModel(monitored: ["nativeSegwit"])

        vm.updateDevices(knownDevices: [standard, hidden], connectedDeviceId: "dev1", connectedWalletId: hiddenWalletId)

        let connected = vm.wallets.filter(\.isConnected)
        XCTAssertEqual(connected.map(\.id), [hiddenWalletId])
    }

    /// A session opened before its identity could be resolved reports none and stays inclusive.
    func testUnresolvedSessionLeavesEveryIdentityOnTheDeviceConnected() {
        let standard = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zStandard"])
        let hidden = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zHidden"])
        let vm = makeViewModel(monitored: ["nativeSegwit"])

        vm.updateDevices(knownDevices: [standard, hidden], connectedDeviceId: "dev1", connectedWalletId: nil)

        XCTAssertEqual(vm.wallets.filter(\.isConnected).count, 2)
    }

    func testRemovingOneIdentityLeavesTheOtherWatched() async throws {
        let mock = MockWatcherService()
        let standard = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zStandard"])
        let hidden = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zHidden"])
        let hiddenWalletId = try HwWalletId.derive(xpubs: hidden.xpubs)
        let vm = makeViewModel(watcherService: mock, monitored: ["nativeSegwit"])
        vm.updateDevices(knownDevices: [standard, hidden], connectedDeviceId: nil)
        await waitUntil { mock.startedParams.count == 2 }

        vm.removeDevice(walletId: hiddenWalletId)
        await vm.drainPendingPersists()

        XCTAssertEqual(mock.stoppedWatcherIds, [watcherId(hidden, "nativeSegwit")], "only the removed identity stops watching")
        XCTAssertEqual(deleted, [hiddenWalletId], "only the removed identity's activities are deleted")
        XCTAssertTrue(vm.wallets.contains { $0.id == (try? HwWalletId.derive(xpubs: standard.xpubs)) })
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

        vm.handleWatcherEvent(watcherId: watcherId(device, "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "t1", value: 40000, txType: .received)], total: 40000
        ))
        XCTAssertEqual(vm.wallets.first?.balanceSats, 40000)

        // Stop fails → the watcher must stay active and keep feeding its balance.
        mock.stopShouldFail = true
        vm.updateDevices(knownDevices: [makeDevice(id: "dev1", xpubs: [:])], connectedDeviceId: nil)
        XCTAssertTrue(mock.stoppedWatcherIds.contains(watcherId(device, "nativeSegwit")))

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

        try vm.removeDevice(walletId: HwWalletId.derive(xpubs: xpubs))

        XCTAssertTrue(mock.stoppedWatcherIds.contains(watcherId("dev1", "nativeSegwit")))
        await vm.drainPendingPersists()
        XCTAssertEqual(deleted, try [HwWalletId.derive(xpubs: xpubs)])
    }

    /// The same wallet stored under two entries is one identity, so removing it deletes its
    /// activities once. Forgetting the stored entries is the session's job — see
    /// `HwWalletManagerPassphraseTests`.
    func testRemoveWalletDeletesTheIdentitysActivitiesOnce() async throws {
        let xpubs = ["nativeSegwit": "z"]
        let devices = [
            makeDevice(id: "dev1", xpubs: xpubs),
            makeDevice(id: "dev2", xpubs: xpubs),
        ]
        let vm = makeViewModel(monitored: ["nativeSegwit"])
        vm.updateDevices(knownDevices: devices, connectedDeviceId: nil)
        let wallet = try XCTUnwrap(vm.wallets.first)

        await vm.removeWallet(walletId: wallet.id)

        await vm.drainPendingPersists()
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

        await vm.drainPendingPersists()
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

        await vm.drainPendingPersists()
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

    // MARK: - Snapshot completeness

    // A snapshot may only prune stored rows it does not mention once every watcher the wallet
    // wants has reported. Pruning a partial snapshot deletes the rows the silent watcher owns —
    // and core cascades that delete into `activity_tags`, so the user's tags go with them.

    func testSingleMonitoredTypeIsCompleteOnFirstEvent() async {
        let vm = makeViewModel(monitored: ["nativeSegwit"])
        vm.updateDevices(knownDevices: [makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zNS"])], connectedDeviceId: nil)

        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "tx1", value: 40000, txType: .received)], total: 40000
        ))

        await vm.drainPendingPersists()
        XCTAssertEqual(persistedSnapshots.count, 1)
        XCTAssertEqual(persistedSnapshots.last?.isComplete, true, "the common single-watcher case must still prune")
    }

    func testPartialSnapshotIsMarkedIncompleteUntilEveryMonitoredWatcherReports() async {
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zNS", "taproot": "zTR"])
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)

        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "txNS", value: 40000, txType: .received)], total: 40000
        ))
        await vm.drainPendingPersists()
        XCTAssertEqual(persistedSnapshots.count, 1)
        XCTAssertEqual(persistedSnapshots.last?.isComplete, false, "taproot has not reported, so txTR must not be pruned")

        vm.handleWatcherEvent(watcherId: watcherId("dev1", "taproot"), event: makeEvent(
            [makeActivity(txId: "txTR", value: 10000, txType: .received)], total: 10000
        ))
        await vm.drainPendingPersists()
        XCTAssertEqual(persistedSnapshots.last?.isComplete, true)
        XCTAssertEqual(
            persistedSnapshots.last?.activities.map(\.activityId).sorted(),
            ["txNS", "txTR"]
        )
    }

    func testGroupBecomingCompleteRepersistsEvenWhenContentUnchanged() async {
        // Both watchers see the same transaction, so the merged content never changes — but the
        // second event is what makes the group complete, and therefore what applies the deletions
        // the first (partial) one deferred. Without `isComplete` in the cache key it is swallowed.
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zNS", "taproot": "zTR"])
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        let shared = makeActivity(txId: "tx1", value: 40000, txType: .received)

        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent([shared], total: 40000))
        vm.handleWatcherEvent(watcherId: watcherId("dev1", "taproot"), event: makeEvent([shared], total: 40000))

        await vm.drainPendingPersists()
        XCTAssertEqual(persistedSnapshots.count, 2)
        XCTAssertEqual(persistedSnapshots.first?.isComplete, false)
        XCTAssertEqual(persistedSnapshots.last?.isComplete, true)
    }

    func testWatcherRestartMakesGroupIncompleteAgain() async {
        // Stopping a watcher clears its cached data, so the group is partial again until it
        // re-reports — the other half of the same hazard.
        let mock = MockWatcherService()
        var electrum = "ssl://a:1"
        let vm = HwWalletManager(
            watcherService: mock,
            monitoredTypes: { ["nativeSegwit", "taproot"] },
            electrumUrl: { electrum },
            network: { .regtest },
            persistSnapshot: { [weak self] in self?.persistedSnapshots.append($0) },
            deleteActivities: { _ in }
        )
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zNS", "taproot": "zTR"])
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        await waitUntil { mock.startedParams.count == 2 }

        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "txNS", value: 40000, txType: .received)], total: 40000
        ))
        vm.handleWatcherEvent(watcherId: watcherId("dev1", "taproot"), event: makeEvent(
            [makeActivity(txId: "txTR", value: 10000, txType: .received)], total: 10000
        ))
        await vm.drainPendingPersists()
        XCTAssertEqual(persistedSnapshots.last?.isComplete, true)

        electrum = "ssl://b:2"
        vm.reconcileForSettingsChange()
        await waitUntil { mock.startedParams.count == 4 }

        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "txNS", value: 50000, txType: .received)], total: 50000
        ))
        await vm.drainPendingPersists()
        XCTAssertEqual(persistedSnapshots.last?.isComplete, false)
    }

    func testUnmonitoringAddressTypeKeepsGroupComplete() async {
        // Dropping an address type removes its spec, so the group is complete without it and its
        // rows are pruned. Intended — and the only remaining path that deletes hardware tags.
        let mock = MockWatcherService()
        var monitored: Set = ["nativeSegwit", "taproot"]
        let vm = HwWalletManager(
            watcherService: mock,
            monitoredTypes: { monitored },
            electrumUrl: { "ssl://test:1" },
            network: { .regtest },
            persistSnapshot: { [weak self] in self?.persistedSnapshots.append($0) },
            deleteActivities: { _ in }
        )
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zNS", "taproot": "zTR"])
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        await waitUntil { mock.startedParams.count == 2 }

        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "txNS", value: 40000, txType: .received)], total: 40000
        ))
        vm.handleWatcherEvent(watcherId: watcherId("dev1", "taproot"), event: makeEvent(
            [makeActivity(txId: "txTR", value: 10000, txType: .received)], total: 10000
        ))

        monitored = ["nativeSegwit"]
        vm.reconcileForSettingsChange()
        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "txNS", value: 50000, txType: .received)], total: 50000
        ))

        await vm.drainPendingPersists()
        XCTAssertEqual(persistedSnapshots.last?.isComplete, true)
        XCTAssertEqual(persistedSnapshots.last?.activities.map(\.activityId), ["txNS"])
    }

    func testWatcherThatFailsToStartKeepsSnapshotsIncomplete() async {
        // Accepted degradation: a watcher that cannot start suspends pruning for its wallet. A
        // lingering replaced row is cosmetic and self-heals; destroying tags does not.
        let mock = MockWatcherService()
        mock.startFailures = [watcherId("dev1", "taproot")]
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zNS", "taproot": "zTR"])
        let vm = makeViewModel(watcherService: mock)
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        await waitUntil { mock.startedParams.count == 2 }

        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeActivity(txId: "txNS", value: 40000, txType: .received)], total: 40000
        ))

        await vm.drainPendingPersists()
        XCTAssertEqual(persistedSnapshots.last?.isComplete, false)
    }

    func testEmptySnapshotFromTheOnlyWatcherIsComplete() async {
        // Core only emits `transactionsChanged` after a successful sync, so an empty snapshot from
        // the wallet's only watcher genuinely means "no transactions" and must prune.
        let vm = makeViewModel(monitored: ["nativeSegwit"])
        vm.updateDevices(knownDevices: [makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zNS"])], connectedDeviceId: nil)

        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent([], total: 0))

        await vm.drainPendingPersists()
        XCTAssertEqual(persistedSnapshots.count, 1)
        XCTAssertTrue(persistedSnapshots[0].activities.isEmpty)
        XCTAssertEqual(persistedSnapshots[0].isComplete, true)
    }

    // MARK: - Persist failure recovery

    private final class PersistSpy {
        struct WriteError: Error {}

        var snapshots: [HwWalletSnapshot] = []
        var failNextWrite = false

        func record(_ snapshot: HwWalletSnapshot) throws {
            snapshots.append(snapshot)
            if failNextWrite {
                failNextWrite = false
                throw WriteError()
            }
        }
    }

    func testFailedPersistIsRetriedByTheNextIdenticalSnapshot() async {
        // `persistGroupSnapshot` records a snapshot as persisted before the write is queued, so a
        // transient core failure must drop that entry — otherwise the dedupe check swallows every
        // identical retry and the wallet stays stale until its content happens to change.
        let spy = PersistSpy()
        spy.failNextWrite = true
        let vm = HwWalletManager(
            watcherService: MockWatcherService(),
            monitoredTypes: { ["nativeSegwit"] },
            electrumUrl: { "ssl://test:1" },
            network: { .regtest },
            persistSnapshot: { try spy.record($0) },
            deleteActivities: { _ in }
        )
        vm.updateDevices(knownDevices: [makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zNS"])], connectedDeviceId: nil)
        let wid = watcherId("dev1", "nativeSegwit")
        let event = makeEvent([makeActivity(txId: "tx1", value: 40000, txType: .received)], total: 40000)

        vm.handleWatcherEvent(watcherId: wid, event: event)
        await vm.drainPendingPersists()
        XCTAssertEqual(spy.snapshots.count, 1)

        vm.handleWatcherEvent(watcherId: wid, event: event)
        await vm.drainPendingPersists()
        XCTAssertEqual(spy.snapshots.count, 2, "the identical snapshot retries because the failed write cleared the cache")

        // Now that a write has succeeded, the dedupe check is back in force.
        vm.handleWatcherEvent(watcherId: wid, event: event)
        await vm.drainPendingPersists()
        XCTAssertEqual(spy.snapshots.count, 2)
    }

    // MARK: - Persist ordering

    func testSnapshotPersistQueueSerializesPerWallet() async {
        // Writes for one wallet must land in enqueue order: a stale partial snapshot landing after
        // a complete one would resurrect the rows the complete one pruned.
        let queue = SnapshotPersistQueue()
        var order: [String] = []

        queue.enqueue(walletId: "walletA") {
            try? await Task.sleep(nanoseconds: 30_000_000)
            order.append("A1")
        }
        queue.enqueue(walletId: "walletA") { order.append("A2") }
        queue.enqueue(walletId: "walletB") { order.append("B1") }

        await waitUntil { order.count == 3 }
        XCTAssertEqual(order.count, 3)
        XCTAssertLessThan(
            order.firstIndex(of: "A1") ?? .max,
            order.firstIndex(of: "A2") ?? .min,
            "the slow first write for walletA must still land before the fast second one"
        )
        // walletB has its own chain, so it is not held up behind walletA's slow write.
        XCTAssertEqual(order.first, "B1")
    }

    // MARK: - Helpers

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
