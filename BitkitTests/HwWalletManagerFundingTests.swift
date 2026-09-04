@testable import Bitkit
import BitkitCore
import XCTest

/// Funding-account coverage for `HwWalletManager`, adapting the funding cases in bitkit-android's
/// `HwWalletRepoTest`: the native-segwit funding balance is tracked separately from the aggregate
/// balance, and the funding account resolves the stored native-segwit xpub. The engine is driven
/// directly via `updateDevices` + `handleWatcherEvent` (no live device), as in `HwWalletManagerTests`.
@MainActor
final class HwWalletManagerFundingTests: XCTestCase {
    private final class NoopWatcher: OnChainWatcherServicing, @unchecked Sendable {
        func startWatcher(params _: WatcherParams, listener _: EventListener) async throws {}
        func stopWatcher(watcherId _: String) throws {}
        func stopAllWatchers() {}
    }

    private func makeManager(
        monitored: Set<String> = ["legacy", "nestedSegwit", "nativeSegwit", "taproot"]
    ) -> HwWalletManager {
        HwWalletManager(
            watcherService: NoopWatcher(),
            monitoredTypes: { monitored },
            electrumUrl: { "ssl://test:1" },
            network: { .regtest },
            persistSnapshot: { _ in },
            deleteActivities: { _ in }
        )
    }

    private func makeDevice(id: String, xpubs: [String: String]) -> TrezorKnownDevice {
        xpubsByDeviceId[id] = xpubs
        return TrezorKnownDevice(
            id: id,
            name: id,
            path: "ble:\(id)",
            transportType: "bluetooth",
            label: nil,
            model: "Safe 5",
            lastConnectedAt: Date(timeIntervalSince1970: 1000),
            xpubs: xpubs
        )
    }

    private func makeEvent(total: UInt64) -> WatcherEvent {
        let balance = WalletBalance(
            confirmed: total, immature: 0, trustedPending: 0, untrustedPending: 0, spendable: total, total: total
        )
        return .transactionsChanged(
            activities: [],
            transactionDetails: [],
            balance: balance,
            txCount: 0,
            blockHeight: 100,
            accountType: .nativeSegwit,
            nextUnusedExternalAddress: unusedAddress()
        )
    }

    private func unusedAddress() -> BitkitCore.AddressInfo {
        BitkitCore.AddressInfo(address: "bc1qtestunused", path: "m/84'/0'/0'/0/0", transfers: 0)
    }

    /// Watcher ids are keyed by wallet identity, so they are derived from the device's xpubs.
    /// `makeDevice` records them here so tests can keep naming devices by their transport id.
    private var xpubsByDeviceId: [String: [String: String]] = [:]

    private func watcherId(_ deviceId: String, _ addressType: String) -> String {
        "\(walletId(deviceId))|\(addressType)"
    }

    private func walletId(_ deviceId: String) -> String {
        (try? HwWalletId.derive(xpubs: xpubsByDeviceId[deviceId] ?? [:])) ?? deviceId
    }

    func testFundingBalanceIsNativeSegwitOnly() throws {
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zpubNS", "taproot": "zpubTR"])
        let manager = makeManager()
        manager.updateDevices(knownDevices: [device], connectedDeviceId: "dev1")

        manager.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(total: 50000))
        manager.handleWatcherEvent(watcherId: watcherId("dev1", "taproot"), event: makeEvent(total: 30000))

        let wallet = try XCTUnwrap(manager.wallets.first)
        XCTAssertEqual(wallet.balanceSats, 80000, "aggregate balance spans all address types")
        XCTAssertEqual(wallet.fundingBalanceSats, 50000, "funding balance is native-segwit only")
        XCTAssertEqual(manager.fundingBalance(walletId: walletId("dev1")), 50000)
        XCTAssertEqual(manager.fundingBalance(walletId: walletId("dev1"), addressType: .taproot), 30000)
    }

    func testGetFundingAccountReturnsNativeSegwitXpubAndBalance() throws {
        let device = makeDevice(id: "dev1", xpubs: ["nativeSegwit": "zpubNS", "taproot": "zpubTR"])
        let manager = makeManager()
        manager.updateDevices(knownDevices: [device], connectedDeviceId: "dev1")
        manager.handleWatcherEvent(watcherId: watcherId("dev1", "nativeSegwit"), event: makeEvent(total: 42000))

        let account = try manager.getFundingAccount(walletId: walletId("dev1"))
        XCTAssertEqual(account.xpub, "zpubNS")
        XCTAssertEqual(account.addressType, .nativeSegwit)
        XCTAssertEqual(account.accountType, .nativeSegwit)
        XCTAssertEqual(account.balanceSats, 42000)
    }

    func testGetFundingAccountThrowsForUnknownDevice() {
        let manager = makeManager()
        manager.updateDevices(knownDevices: [], connectedDeviceId: nil)
        XCTAssertThrowsError(try manager.getFundingAccount(walletId: walletId("nope")))
    }

    func testGetFundingAccountThrowsWhenNativeSegwitAccountMissing() {
        let device = makeDevice(id: "dev1", xpubs: ["taproot": "zpubTR"])
        let manager = makeManager()
        manager.updateDevices(knownDevices: [device], connectedDeviceId: "dev1")
        XCTAssertThrowsError(try manager.getFundingAccount(walletId: walletId("dev1")))
    }
}
