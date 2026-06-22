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

    private final class MockWatcherService: TrezorWatcherServicing, @unchecked Sendable {
        private(set) var startedParams: [WatcherParams] = []
        private(set) var stoppedWatcherIds: [String] = []
        var stopShouldFail = false

        struct StopError: Error {}

        func startWatcher(params: WatcherParams, listener _: EventListener) async throws {
            startedParams.append(params)
        }

        func stopWatcher(watcherId: String) throws {
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
        watcherService: TrezorWatcherServicing = MockWatcherService(),
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

    private func makeTx(
        txid: String,
        received: UInt64,
        sent: UInt64,
        fee: UInt64? = nil,
        direction: TxDirection,
        confirmations: UInt32 = 1,
        timestamp: UInt64? = 1_700_000_000
    ) -> HistoryTransaction {
        let amount: UInt64 = direction == .received ? received : (sent >= received ? sent - received : 0)
        return HistoryTransaction(
            txid: txid,
            received: received,
            sent: sent,
            net: Int64(received) - Int64(sent),
            fee: fee,
            amount: amount,
            direction: direction,
            blockHeight: confirmations > 0 ? 100 : nil,
            timestamp: timestamp,
            confirmations: confirmations
        )
    }

    private func makeEvent(_ transactions: [HistoryTransaction], total: UInt64) -> WatcherEvent {
        let balance = WalletBalance(
            confirmed: total, immature: 0, trustedPending: 0, untrustedPending: 0, spendable: total, total: total
        )
        return .transactionsChanged(
            transactions: transactions, balance: balance, txCount: UInt32(transactions.count), blockHeight: 100, accountType: .nativeSegwit
        )
    }

    private func watcherId(_ deviceId: String, _ addressType: String) -> String {
        "\(deviceId)|\(addressType)"
    }

    // MARK: - Tests

    func testPairedDeviceProducesWalletWithBalanceAndWalletId() {
        let xpubs = ["nativeSegwit": "zpubNS"]
        let device = makeDevice(id: "dev1", xpubs: xpubs, model: "Safe 5")
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: "dev1")

        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeTx(txid: "tx1", received: 50000, sent: 0, direction: .received)], total: 50000
        ))

        XCTAssertEqual(vm.wallets.count, 1)
        let wallet = vm.wallets[0]
        XCTAssertEqual(wallet.id, "dev1")
        XCTAssertEqual(wallet.balanceSats, 50000)
        XCTAssertEqual(wallet.name, "Trezor Safe 5")
        XCTAssertTrue(wallet.isConnected)
        XCTAssertEqual(vm.totalSats, 50000)
        XCTAssertEqual(wallet.walletId, HwWalletId.derive(xpubs: xpubs, fallbackId: "dev1"))
        XCTAssertEqual(vm.hwWalletIds, [wallet.walletId])
    }

    func testBalanceAggregatesAcrossAddressTypes() {
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zpubNS", "taproot": "zpubTR"])
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)

        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeTx(txid: "txNS", received: 30000, sent: 0, direction: .received)], total: 30000
        ))
        vm.handleWatcherEvent(watcherId: watcherId("dev1", "taproot"), event: makeEvent(
            [makeTx(txid: "txTR", received: 20000, sent: 0, direction: .received)], total: 20000
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
            [makeTx(txid: "tx1", received: 70000, sent: 0, direction: .received)], total: 70000
        ))

        XCTAssertEqual(vm.wallets.count, 1)
        XCTAssertEqual(vm.wallets[0].deviceIds, ["ble1", "usb1"])
        // Representative is the most recently connected entry.
        XCTAssertEqual(vm.wallets[0].id, "usb1")
        XCTAssertEqual(vm.hwWalletIds.count, 1)
    }

    func testActivityPersistedWithDeviceWalletId() {
        let xpubs = ["nativeSegwit": "zpubNS"]
        let device = makeDevice(id: "dev1", xpubs: xpubs)
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: "dev1")

        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeTx(txid: "txABC", received: 40000, sent: 0, direction: .received)], total: 40000
        ))

        let expectedWalletId = HwWalletId.derive(xpubs: xpubs, fallbackId: "dev1")
        XCTAssertEqual(persisted.count, 1)
        let activities = persisted[0]
        XCTAssertEqual(activities.count, 1)
        guard case let .onchain(onchain) = activities[0] else { return XCTFail("expected onchain activity") }
        XCTAssertEqual(onchain.walletId, expectedWalletId)
        XCTAssertEqual(onchain.txId, "txABC")
        XCTAssertEqual(onchain.txType, .received)
        XCTAssertEqual(onchain.value, 40000)
    }

    func testReceivedTxDetection() {
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zpubNS"])
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: "dev1")
        let wid = watcherId("dev1", "nativeSegwit")

        // Baseline (first event) — must NOT emit, even for received txs.
        vm.handleWatcherEvent(watcherId: wid, event: makeEvent(
            [makeTx(txid: "old", received: 10000, sent: 0, direction: .received)], total: 10000
        ))
        XCTAssertTrue(receivedTxs.isEmpty)

        // New inbound tx after baseline — emits once.
        vm.handleWatcherEvent(watcherId: wid, event: makeEvent(
            [
                makeTx(txid: "old", received: 10000, sent: 0, direction: .received),
                makeTx(txid: "new", received: 25000, sent: 0, direction: .received),
            ], total: 35000
        ))
        XCTAssertEqual(receivedTxs.map(\.txid), ["new"])
        XCTAssertEqual(receivedTxs.first?.sats, 25000)

        // Outbound tx is ignored, and the same inbound is not re-emitted.
        vm.handleWatcherEvent(watcherId: wid, event: makeEvent(
            [
                makeTx(txid: "old", received: 10000, sent: 0, direction: .received),
                makeTx(txid: "new", received: 25000, sent: 0, direction: .received),
                makeTx(txid: "spend", received: 0, sent: 5000, fee: 200, direction: .sent),
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

    func testResetStateDeletesStoredActivitiesAndClears() {
        let xpubs = ["nativeSegwit": "zpubNS"]
        let device = makeDevice(id: "dev1", xpubs: xpubs)
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: "dev1")
        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeTx(txid: "tx1", received: 40000, sent: 0, direction: .received)], total: 40000
        ))

        let walletId = HwWalletId.derive(xpubs: xpubs, fallbackId: "dev1")
        vm.resetState()

        XCTAssertEqual(deleted, [walletId])
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

    func testMergesDuplicateTxAcrossAddressTypes() {
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zNS", "taproot": "zTR"])
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)

        // Same txid reported by two address-type watchers — merged into one activity, amounts summed.
        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeTx(txid: "shared", received: 30000, sent: 0, direction: .received)], total: 30000
        ))
        vm.handleWatcherEvent(watcherId: watcherId("dev1", "taproot"), event: makeEvent(
            [makeTx(txid: "shared", received: 20000, sent: 0, direction: .received)], total: 20000
        ))

        let lastPersisted = persisted.last ?? []
        XCTAssertEqual(lastPersisted.count, 1)
        guard case let .onchain(onchain) = lastPersisted[0] else { return XCTFail("expected onchain") }
        XCTAssertEqual(onchain.txId, "shared")
        XCTAssertEqual(onchain.value, 50000)
    }

    func testSentTxValueExcludesFee() {
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "z"])
        let vm = makeViewModel()
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeTx(txid: "spend", received: 0, sent: 20000, fee: 500, direction: .sent)], total: 0
        ))
        guard case let .onchain(onchain) = (persisted.last ?? [])[0] else { return XCTFail("expected onchain") }
        XCTAssertEqual(onchain.txType, .sent)
        XCTAssertEqual(onchain.value, 19500) // sent - received - fee
        XCTAssertEqual(onchain.fee, 500)
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
        let tx = makeTx(txid: "new", received: 10000, sent: 0, direction: .received)
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
            [makeTx(txid: "t1", received: 1000, sent: 0, direction: .received)], total: .max
        ))
        vm.handleWatcherEvent(watcherId: watcherId("d2", "nativeSegwit"), event: makeEvent(
            [makeTx(txid: "t2", received: 1000, sent: 0, direction: .received)], total: 1000
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
            [makeTx(txid: "t1", received: 40000, sent: 0, direction: .received)], total: 40000
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

    func testRemoveDeviceStopsWatchersAndDeletesActivities() async {
        let mock = MockWatcherService()
        let xpubs = ["nativeSegwit": "z"]
        let device = makeDevice(id: "dev1", xpubs: xpubs)
        let vm = makeViewModel(watcherService: mock, monitored: ["nativeSegwit"])
        vm.updateDevices(knownDevices: [device], connectedDeviceId: nil)
        await waitUntil { mock.startedParams.count == 1 }
        vm.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(
            [makeTx(txid: "t1", received: 1000, sent: 0, direction: .received)], total: 1000
        ))

        vm.removeDevice(id: "dev1")

        XCTAssertTrue(mock.stoppedWatcherIds.contains(watcherId("dev1", "nativeSegwit")))
        XCTAssertEqual(deleted, [HwWalletId.derive(xpubs: xpubs, fallbackId: "dev1")])
    }

    // MARK: - Helpers

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
