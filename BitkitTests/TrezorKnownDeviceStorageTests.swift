@testable import Bitkit
import XCTest

/// Covers identity-scoped reads and writes: one physical device can hold a standard wallet plus its
/// passphrase wallets, so `id` no longer identifies a stored entry on its own.
final class TrezorKnownDeviceStorageTests: XCTestCase {
    private static let storageKey = "trezor.knownDevices"
    private var savedDefaults: Data?

    override func setUp() {
        super.setUp()
        savedDefaults = UserDefaults.standard.data(forKey: Self.storageKey)
        TrezorKnownDeviceStorage.removeAll()
    }

    override func tearDown() {
        if let savedDefaults {
            UserDefaults.standard.set(savedDefaults, forKey: Self.storageKey)
        } else {
            TrezorKnownDeviceStorage.removeAll()
        }
        super.tearDown()
    }

    func testSavingAPassphraseWalletKeepsTheStandardWalletOfTheSameDevice() {
        TrezorKnownDeviceStorage.save(makeDevice(xpubs: ["nativeSegwit": "zStandard"], walletId: "trezor:standard"))
        TrezorKnownDeviceStorage.save(makeDevice(
            xpubs: ["nativeSegwit": "zHidden"],
            walletId: "trezor:hidden",
            passphraseProtected: true
        ))

        let stored = TrezorKnownDeviceStorage.loadAll()
        XCTAssertEqual(Set(stored.compactMap(\.walletId)), ["trezor:standard", "trezor:hidden"])
        XCTAssertEqual(stored.filter(\.passphraseProtected).count, 1)
    }

    func testSavingTheSameIdentityAgainReplacesIt() {
        TrezorKnownDeviceStorage.save(makeDevice(xpubs: ["nativeSegwit": "zStandard"], customLabel: "Old"))
        TrezorKnownDeviceStorage.save(makeDevice(xpubs: ["nativeSegwit": "zStandard"], customLabel: "New"))

        XCTAssertEqual(TrezorKnownDeviceStorage.loadAll().map(\.customLabel), ["New"])
    }

    func testRemovingOneWalletLeavesTheDevicesOtherWalletsPaired() {
        TrezorKnownDeviceStorage.save(makeDevice(xpubs: ["nativeSegwit": "zStandard"], walletId: "trezor:standard"))
        TrezorKnownDeviceStorage.save(makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: "trezor:hidden"))

        TrezorKnownDeviceStorage.remove(walletId: "trezor:hidden")

        XCTAssertEqual(TrezorKnownDeviceStorage.loadAll().compactMap(\.walletId), ["trezor:standard"])
        XCTAssertTrue(TrezorKnownDeviceStorage.isKnown(id: "dev1"), "the device itself stays paired")
    }

    /// Entries written before the wallet id was persisted resolve it from their xpubs.
    func testRemovingAWalletMatchesEntriesWithoutAStoredWalletId() throws {
        let legacy = makeDevice(xpubs: ["nativeSegwit": "zStandard"], walletId: nil)
        TrezorKnownDeviceStorage.save(legacy)

        try TrezorKnownDeviceStorage.remove(walletId: HwWalletId.derive(xpubs: legacy.xpubs))

        XCTAssertTrue(TrezorKnownDeviceStorage.loadAll().isEmpty)
    }

    func testRemovingByDeviceIdForgetsEveryWalletItHolds() {
        TrezorKnownDeviceStorage.save(makeDevice(xpubs: ["nativeSegwit": "zStandard"], walletId: "trezor:standard"))
        TrezorKnownDeviceStorage.save(makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: "trezor:hidden"))
        TrezorKnownDeviceStorage.save(makeDevice(id: "dev2", xpubs: ["nativeSegwit": "zOther"], walletId: "trezor:other"))

        TrezorKnownDeviceStorage.remove(id: "dev1")

        XCTAssertEqual(TrezorKnownDeviceStorage.loadAll().compactMap(\.walletId), ["trezor:other"])
    }

    func testLoadingByWalletIdReturnsOnlyThatIdentitysEntries() {
        TrezorKnownDeviceStorage.save(makeDevice(xpubs: ["nativeSegwit": "zStandard"], walletId: "trezor:standard"))
        TrezorKnownDeviceStorage.save(makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: "trezor:hidden"))

        let entries = TrezorKnownDeviceStorage.loadAll(walletId: "trezor:hidden")

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.xpubs, ["nativeSegwit": "zHidden"])
    }

    func testNewFieldsSurviveAStorageRoundTrip() {
        TrezorKnownDeviceStorage.save(makeDevice(
            xpubs: ["nativeSegwit": "zHidden"],
            walletId: "trezor:hidden",
            passphraseProtected: true,
            trezorDeviceId: "trezor-id"
        ))

        let stored = TrezorKnownDeviceStorage.loadAll().first
        XCTAssertEqual(stored?.walletId, "trezor:hidden")
        XCTAssertTrue(stored?.passphraseProtected == true)
        XCTAssertEqual(stored?.trezorDeviceId, "trezor-id")
    }

    private func makeDevice(
        id: String = "dev1",
        xpubs: [String: String],
        customLabel: String? = nil,
        walletId: String? = nil,
        passphraseProtected: Bool = false,
        trezorDeviceId: String? = nil
    ) -> TrezorKnownDevice {
        TrezorKnownDevice(
            id: id,
            name: "Trezor",
            path: "ble://\(id)",
            transportType: "bluetooth",
            lastConnectedAt: Date(timeIntervalSince1970: 0),
            xpubs: xpubs,
            customLabel: customLabel,
            walletId: walletId,
            passphraseProtected: passphraseProtected,
            trezorDeviceId: trezorDeviceId
        )
    }
}
