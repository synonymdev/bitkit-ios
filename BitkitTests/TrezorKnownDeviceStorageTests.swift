@testable import Bitkit
import Combine
import XCTest

/// Covers identity-scoped reads and writes: one physical device can hold a standard wallet plus its
/// passphrase wallets, so `id` no longer identifies a stored entry on its own.
final class TrezorKnownDeviceStorageTests: XCTestCase {
    private static let storageKey = "trezor.knownDevices"
    private static let pendingNamesKey = "trezor.pendingWalletNames"
    private var savedDefaults: Data?
    private var savedPendingNames: [String: String]?
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        savedDefaults = UserDefaults.standard.data(forKey: Self.storageKey)
        savedPendingNames = UserDefaults.standard.dictionary(forKey: Self.pendingNamesKey) as? [String: String]
        cancellables = []
        TrezorKnownDeviceStorage.removeAll()
    }

    override func tearDown() {
        cancellables = []
        TrezorKnownDeviceStorage.removeAll()
        if let savedDefaults {
            UserDefaults.standard.set(savedDefaults, forKey: Self.storageKey)
        }
        if let savedPendingNames {
            UserDefaults.standard.set(savedPendingNames, forKey: Self.pendingNamesKey)
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

    // MARK: - Hardware wallet names

    func testAPendingNameAndTheDeviceListAreWrittenTogether() {
        let device = makeDevice(xpubs: ["nativeSegwit": "zStandard"], customLabel: "Cold", walletId: "trezor:standard")
        TrezorKnownDeviceStorage.save(device)

        TrezorKnownDeviceStorage.saveAll([], pendingName: PendingHwWalletName(walletId: "trezor:standard", name: "Cold"))

        XCTAssertTrue(TrezorKnownDeviceStorage.loadAll().isEmpty)
        XCTAssertEqual(TrezorKnownDeviceStorage.loadPendingNames(), ["trezor:standard": "Cold"])
    }

    /// Adoption on pairing consumes a pending name by masking rather than by a second write, so a
    /// wallet the device list already names must not report one.
    func testAPendingNameIsMaskedOnceTheWalletIsPairedAndNamed() {
        TrezorKnownDeviceStorage.setPendingName(walletId: "trezor:standard", name: "Cold")
        TrezorKnownDeviceStorage.save(
            makeDevice(xpubs: ["nativeSegwit": "zStandard"], customLabel: "Cold", walletId: "trezor:standard")
        )

        XCTAssertTrue(TrezorKnownDeviceStorage.loadPendingNames().isEmpty)
        XCTAssertEqual(TrezorKnownDeviceStorage.backupSnapshot(), ["trezor:standard": "Cold"])
    }

    func testTheNameOfAPairedWalletWinsOverAPendingOne() {
        TrezorKnownDeviceStorage.setPendingName(walletId: "trezor:standard", name: "Restored")
        TrezorKnownDeviceStorage.save(
            makeDevice(xpubs: ["nativeSegwit": "zStandard"], customLabel: "Renamed", walletId: "trezor:standard")
        )

        XCTAssertEqual(TrezorKnownDeviceStorage.backupSnapshot(), ["trezor:standard": "Renamed"])
    }

    func testSettingAPendingNameToNilDropsIt() {
        TrezorKnownDeviceStorage.setPendingName(walletId: "trezor:standard", name: "Cold")
        TrezorKnownDeviceStorage.setPendingName(walletId: "trezor:standard", name: nil)

        XCTAssertTrue(TrezorKnownDeviceStorage.backupSnapshot().isEmpty)
    }

    func testRestoringNamesLetsALocalNameWinAndNeverClears() {
        TrezorKnownDeviceStorage.setPendingName(walletId: "trezor:standard", name: "Local")

        TrezorKnownDeviceStorage.restoreNames(["trezor:standard": "Backed up", "trezor:hidden": "Hidden"])
        XCTAssertEqual(
            TrezorKnownDeviceStorage.backupSnapshot(),
            ["trezor:standard": "Local", "trezor:hidden": "Hidden"]
        )

        // An envelope written before the field carries no names, and must not drop what is stored.
        TrezorKnownDeviceStorage.restoreNames([:])
        XCTAssertEqual(
            TrezorKnownDeviceStorage.backupSnapshot(),
            ["trezor:standard": "Local", "trezor:hidden": "Hidden"]
        )
    }

    func testForgettingAWalletDropsTheNameKeptForIt() {
        TrezorKnownDeviceStorage.setPendingName(walletId: "trezor:hidden", name: "Hidden")
        TrezorKnownDeviceStorage.save(makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: "trezor:hidden"))

        TrezorKnownDeviceStorage.remove(walletId: "trezor:hidden")

        XCTAssertTrue(TrezorKnownDeviceStorage.backupSnapshot().isEmpty)
    }

    func testRemoveAllClearsPendingNamesToo() {
        TrezorKnownDeviceStorage.setPendingName(walletId: "trezor:standard", name: "Cold")

        TrezorKnownDeviceStorage.removeAll()

        XCTAssertTrue(TrezorKnownDeviceStorage.backupSnapshot().isEmpty)
    }

    /// Every connect rewrites the device list to refresh `lastConnectedAt`; only a name change may
    /// mark the metadata backup stale.
    func testTheNameSignalFiresOnARenameButNotOnAReconnect() {
        let device = makeDevice(xpubs: ["nativeSegwit": "zStandard"], customLabel: "Cold", walletId: "trezor:standard")
        TrezorKnownDeviceStorage.save(device)

        var fires = 0
        TrezorKnownDeviceStorage.namesChangedPublisher
            .sink { fires += 1 }
            .store(in: &cancellables)

        var reconnected = device
        reconnected.lastConnectedAt = Date(timeIntervalSince1970: 5000)
        TrezorKnownDeviceStorage.saveAll([reconnected])
        XCTAssertEqual(fires, 0, "a reconnect must not re-upload the metadata envelope")

        var renamed = reconnected
        renamed.customLabel = "Vault"
        TrezorKnownDeviceStorage.saveAll([renamed])
        XCTAssertEqual(fires, 1)
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
