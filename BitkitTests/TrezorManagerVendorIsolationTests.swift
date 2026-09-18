@testable import Bitkit
import XCTest

/// Trezor reads and writes only its own slice of the paired-device store, so nothing it loads, renames
/// or forgets can reach a paired Jade, not even one holding the same seed.
@MainActor
final class TrezorManagerVendorIsolationTests: XCTestCase {
    private static let storageKey = "trezor.knownDevices"
    private static let pendingNamesKey = "trezor.pendingWalletNames"
    private static let sharedSeed = ["nativeSegwit": "zShared"]

    private var savedDefaults: Data?
    private var savedPendingNames: [String: String]?

    override func setUp() {
        super.setUp()
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
        super.tearDown()
    }

    func testLoadingKnownDevicesSeesOnlyTrezorEntries() {
        HwKnownDeviceStorage.save(makeTrezor(walletId: "trezor:standard"))
        HwKnownDeviceStorage.save(makeJade())
        let manager = TrezorManager()

        manager.loadKnownDevices()

        XCTAssertEqual(manager.knownDevices.map(\.walletId), ["trezor:standard"])
        XCTAssertEqual(manager.storedDevices.map(\.vendor), [.trezor])
    }

    func testRenamingATrezorWalletLeavesTheJadeUntouched() {
        HwKnownDeviceStorage.save(makeTrezor(walletId: "trezor:standard"))
        let jade = makeJade()
        HwKnownDeviceStorage.save(jade)

        TrezorManager().renameWallet(walletId: "trezor:standard", newName: "Vault")

        XCTAssertEqual(HwKnownDeviceStorage.loadAll(vendor: .trezor).map(\.customLabel), ["Vault"])
        XCTAssertEqual(HwKnownDeviceStorage.loadAll(vendor: .blockstream), [jade])
    }

    /// Renaming a device also renames every entry holding its xpubs, which must stop at the Trezor
    /// slice: a Jade restored from the same seed is a different wallet.
    func testRenamingATrezorDeviceLeavesAJadeWithTheSameSeedUntouched() {
        HwKnownDeviceStorage.save(makeTrezor(walletId: "trezor:standard"))
        let jade = makeJade()
        HwKnownDeviceStorage.save(jade)

        TrezorManager().renameDevice(id: "trezor-dev", newName: "Vault")

        XCTAssertEqual(HwKnownDeviceStorage.loadAll(vendor: .trezor).map(\.customLabel), ["Vault"])
        XCTAssertEqual(HwKnownDeviceStorage.loadAll(vendor: .blockstream), [jade])
    }

    func testRenamingAJadeWalletThroughTrezorChangesNothing() {
        let jade = makeJade()
        HwKnownDeviceStorage.save(jade)

        TrezorManager().renameWallet(walletId: "jade:wallet", newName: "Vault")

        XCTAssertEqual(HwKnownDeviceStorage.loadAll(vendor: .blockstream), [jade])
    }

    /// The hidden wallet's sibling stays paired, so no transport credential is cleared.
    func testForgettingATrezorWalletKeepsTheJade() async {
        HwKnownDeviceStorage.save(makeTrezor(walletId: "trezor:standard"))
        HwKnownDeviceStorage.save(makeTrezor(xpubs: ["nativeSegwit": "zHidden"], walletId: "trezor:hidden"))
        let jade = makeJade()
        HwKnownDeviceStorage.save(jade)
        let manager = TrezorManager()
        manager.loadKnownDevices()

        await manager.forgetWallet(walletId: "trezor:hidden")

        XCTAssertEqual(HwKnownDeviceStorage.loadAll(vendor: .trezor).compactMap(\.walletId), ["trezor:standard"])
        XCTAssertEqual(HwKnownDeviceStorage.loadAll(vendor: .blockstream), [jade])
    }

    func testForgettingAJadeWalletThroughTrezorChangesNothing() async {
        let jade = makeJade()
        HwKnownDeviceStorage.save(jade)

        await TrezorManager().forgetWallet(walletId: "jade:wallet")

        XCTAssertEqual(HwKnownDeviceStorage.loadAll(vendor: .blockstream), [jade])
    }

    func testForgettingADeviceIdOnlyAJadeHoldsChangesNothing() async {
        let jade = makeJade()
        HwKnownDeviceStorage.save(jade)
        let manager = TrezorManager()
        manager.loadKnownDevices()

        await manager.forgetDevice(id: jade.id)

        XCTAssertEqual(HwKnownDeviceStorage.loadAll(vendor: .blockstream), [jade])
    }

    private func makeTrezor(xpubs: [String: String] = ["nativeSegwit": "zShared"], walletId: String) -> HwKnownDevice {
        HwKnownDevice(
            id: "trezor-dev",
            name: "Trezor",
            path: "ble:trezor",
            transportType: "bluetooth",
            model: "Safe 7",
            lastConnectedAt: Date(timeIntervalSince1970: 0),
            xpubs: xpubs,
            walletId: walletId
        )
    }

    private func makeJade() -> HwKnownDevice {
        HwKnownDevice(
            id: "jade:bluetooth:aabbcc",
            name: "Jade AABBCC",
            path: "ble:jade",
            transportType: "bluetooth",
            model: "Jade",
            lastConnectedAt: Date(timeIntervalSince1970: 10),
            xpubs: Self.sharedSeed,
            customLabel: "Travel",
            walletId: "jade:wallet",
            vendor: .blockstream,
            jadeDeviceId: "aabbcc"
        )
    }
}
