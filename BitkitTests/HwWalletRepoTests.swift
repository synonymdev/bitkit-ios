@testable import Bitkit
import BitkitCore
import Combine
import XCTest

/// Engine tests for `HwWalletRepo`, adapting bitkit-android's `HwWalletRepoTest`.
/// The engine is driven directly (no live `TrezorViewModel`) via `updateDevices` and
/// `handleWatcherEvent`, with spies for the bitkit-core persistence side.
@MainActor
final class HwWalletRepoTests: XCTestCase {
    // MARK: - Mocks & spies

    private final class MockWatcherService: TrezorWatcherServicing, @unchecked Sendable {
        private(set) var startedParams: [WatcherParams] = []
        private(set) var stoppedWatcherIds: [String] = []

        func startWatcher(params: WatcherParams, listener _: EventListener) async throws {
            startedParams.append(params)
        }

        func stopWatcher(watcherId: String) throws {
            stoppedWatcherIds.append(watcherId)
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
    ) -> HwWalletRepo {
        let vm = HwWalletRepo(
            trezor: nil,
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

    // MARK: - Helpers

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
