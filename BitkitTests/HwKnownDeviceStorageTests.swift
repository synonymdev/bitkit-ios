@testable import Bitkit
import Combine
import XCTest

/// Covers identity-scoped reads and writes: one physical device can hold a standard wallet plus its
/// passphrase wallets, so `id` no longer identifies a stored entry on its own. Each vendor also reads
/// and writes only its own slice of the store.
final class HwKnownDeviceStorageTests: XCTestCase {
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
        HwKnownDeviceStorage.removeAll()
    }

    override func tearDown() {
        cancellables = []
        HwKnownDeviceStorage.removeAll()
        if let savedDefaults {
            UserDefaults.standard.set(savedDefaults, forKey: Self.storageKey)
        }
        if let savedPendingNames {
            UserDefaults.standard.set(savedPendingNames, forKey: Self.pendingNamesKey)
        }
        super.tearDown()
    }

    func testSavingAPassphraseWalletKeepsTheStandardWalletOfTheSameDevice() {
        HwKnownDeviceStorage.save(makeDevice(xpubs: ["nativeSegwit": "zStandard"], walletId: "trezor:standard"))
        HwKnownDeviceStorage.save(makeDevice(
            xpubs: ["nativeSegwit": "zHidden"],
            walletId: "trezor:hidden",
            passphraseProtected: true
        ))

        let stored = HwKnownDeviceStorage.loadAll()
        XCTAssertEqual(Set(stored.compactMap(\.walletId)), ["trezor:standard", "trezor:hidden"])
        XCTAssertEqual(stored.filter(\.passphraseProtected).count, 1)
    }

    func testSavingTheSameIdentityAgainReplacesIt() {
        HwKnownDeviceStorage.save(makeDevice(xpubs: ["nativeSegwit": "zStandard"], customLabel: "Old"))
        HwKnownDeviceStorage.save(makeDevice(xpubs: ["nativeSegwit": "zStandard"], customLabel: "New"))

        XCTAssertEqual(HwKnownDeviceStorage.loadAll().map(\.customLabel), ["New"])
    }

    func testRemovingOneWalletLeavesTheDevicesOtherWalletsPaired() {
        HwKnownDeviceStorage.save(makeDevice(xpubs: ["nativeSegwit": "zStandard"], walletId: "trezor:standard"))
        HwKnownDeviceStorage.save(makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: "trezor:hidden"))

        HwKnownDeviceStorage.remove(walletId: "trezor:hidden")

        XCTAssertEqual(HwKnownDeviceStorage.loadAll().compactMap(\.walletId), ["trezor:standard"])
        XCTAssertTrue(HwKnownDeviceStorage.isKnown(id: "dev1"), "the device itself stays paired")
    }

    /// Entries written before the wallet id was persisted resolve it from their xpubs.
    func testRemovingAWalletMatchesEntriesWithoutAStoredWalletId() throws {
        let legacy = makeDevice(xpubs: ["nativeSegwit": "zStandard"], walletId: nil)
        HwKnownDeviceStorage.save(legacy)

        try HwKnownDeviceStorage.remove(walletId: HwWalletId.derive(xpubs: legacy.xpubs))

        XCTAssertTrue(HwKnownDeviceStorage.loadAll().isEmpty)
    }

    func testRemovingByDeviceIdForgetsEveryWalletItHolds() {
        HwKnownDeviceStorage.save(makeDevice(xpubs: ["nativeSegwit": "zStandard"], walletId: "trezor:standard"))
        HwKnownDeviceStorage.save(makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: "trezor:hidden"))
        HwKnownDeviceStorage.save(makeDevice(id: "dev2", xpubs: ["nativeSegwit": "zOther"], walletId: "trezor:other"))

        HwKnownDeviceStorage.remove(id: "dev1", vendor: .trezor)

        XCTAssertEqual(HwKnownDeviceStorage.loadAll().compactMap(\.walletId), ["trezor:other"])
    }

    func testLoadingByWalletIdReturnsOnlyThatIdentitysEntries() {
        HwKnownDeviceStorage.save(makeDevice(xpubs: ["nativeSegwit": "zStandard"], walletId: "trezor:standard"))
        HwKnownDeviceStorage.save(makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: "trezor:hidden"))

        let entries = HwKnownDeviceStorage.loadAll(walletId: "trezor:hidden")

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.xpubs, ["nativeSegwit": "zHidden"])
    }

    func testNewFieldsSurviveAStorageRoundTrip() {
        HwKnownDeviceStorage.save(makeDevice(
            xpubs: ["nativeSegwit": "zHidden"],
            walletId: "trezor:hidden",
            passphraseProtected: true,
            trezorDeviceId: "trezor-id"
        ))

        let stored = HwKnownDeviceStorage.loadAll().first
        XCTAssertEqual(stored?.walletId, "trezor:hidden")
        XCTAssertTrue(stored?.passphraseProtected == true)
        XCTAssertEqual(stored?.trezorDeviceId, "trezor-id")
    }

    // MARK: - Hardware wallet names

    func testAPendingNameAndTheDeviceListAreWrittenTogether() {
        let device = makeDevice(xpubs: ["nativeSegwit": "zStandard"], customLabel: "Cold", walletId: "trezor:standard")
        HwKnownDeviceStorage.save(device)

        HwKnownDeviceStorage.saveAll(
            [],
            vendor: .trezor,
            pendingName: PendingHwWalletName(walletId: "trezor:standard", name: "Cold")
        )

        XCTAssertTrue(HwKnownDeviceStorage.loadAll().isEmpty)
        XCTAssertEqual(HwKnownDeviceStorage.loadPendingNames(), ["trezor:standard": "Cold"])
    }

    /// Adoption on pairing consumes a pending name by masking rather than by a second write, so a
    /// wallet the device list already names must not report one.
    func testAPendingNameIsMaskedOnceTheWalletIsPairedAndNamed() {
        HwKnownDeviceStorage.setPendingName(walletId: "trezor:standard", name: "Cold")
        HwKnownDeviceStorage.save(
            makeDevice(xpubs: ["nativeSegwit": "zStandard"], customLabel: "Cold", walletId: "trezor:standard")
        )

        XCTAssertTrue(HwKnownDeviceStorage.loadPendingNames().isEmpty)
        XCTAssertEqual(HwKnownDeviceStorage.backupSnapshot(), ["trezor:standard": "Cold"])
    }

    func testTheNameOfAPairedWalletWinsOverAPendingOne() {
        HwKnownDeviceStorage.setPendingName(walletId: "trezor:standard", name: "Restored")
        HwKnownDeviceStorage.save(
            makeDevice(xpubs: ["nativeSegwit": "zStandard"], customLabel: "Renamed", walletId: "trezor:standard")
        )

        XCTAssertEqual(HwKnownDeviceStorage.backupSnapshot(), ["trezor:standard": "Renamed"])
    }

    func testSettingAPendingNameToNilDropsIt() {
        HwKnownDeviceStorage.setPendingName(walletId: "trezor:standard", name: "Cold")
        HwKnownDeviceStorage.setPendingName(walletId: "trezor:standard", name: nil)

        XCTAssertTrue(HwKnownDeviceStorage.backupSnapshot().isEmpty)
    }

    func testRestoringNamesLetsALocalNameWinAndNeverClears() {
        HwKnownDeviceStorage.setPendingName(walletId: "trezor:standard", name: "Local")

        HwKnownDeviceStorage.restoreNames(["trezor:standard": "Backed up", "trezor:hidden": "Hidden"])
        XCTAssertEqual(
            HwKnownDeviceStorage.backupSnapshot(),
            ["trezor:standard": "Local", "trezor:hidden": "Hidden"]
        )

        // An envelope written before the field carries no names, and must not drop what is stored.
        HwKnownDeviceStorage.restoreNames([:])
        XCTAssertEqual(
            HwKnownDeviceStorage.backupSnapshot(),
            ["trezor:standard": "Local", "trezor:hidden": "Hidden"]
        )
    }

    func testForgettingAWalletDropsTheNameKeptForIt() {
        HwKnownDeviceStorage.setPendingName(walletId: "trezor:hidden", name: "Hidden")
        HwKnownDeviceStorage.save(makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: "trezor:hidden"))

        HwKnownDeviceStorage.remove(walletId: "trezor:hidden")

        XCTAssertTrue(HwKnownDeviceStorage.backupSnapshot().isEmpty)
    }

    func testRemoveAllClearsPendingNamesToo() {
        HwKnownDeviceStorage.setPendingName(walletId: "trezor:standard", name: "Cold")

        HwKnownDeviceStorage.removeAll()

        XCTAssertTrue(HwKnownDeviceStorage.backupSnapshot().isEmpty)
    }

    /// Every connect rewrites the device list to refresh `lastConnectedAt`; only a name change may
    /// mark the metadata backup stale.
    func testTheNameSignalFiresOnARenameButNotOnAReconnect() {
        let device = makeDevice(xpubs: ["nativeSegwit": "zStandard"], customLabel: "Cold", walletId: "trezor:standard")
        HwKnownDeviceStorage.save(device)

        var fires = 0
        HwKnownDeviceStorage.namesChangedPublisher
            .sink { fires += 1 }
            .store(in: &cancellables)

        var reconnected = device
        reconnected.lastConnectedAt = Date(timeIntervalSince1970: 5000)
        HwKnownDeviceStorage.saveAll([reconnected], vendor: .trezor)
        XCTAssertEqual(fires, 0, "a reconnect must not re-upload the metadata envelope")

        var renamed = reconnected
        renamed.customLabel = "Vault"
        HwKnownDeviceStorage.saveAll([renamed], vendor: .trezor)
        XCTAssertEqual(fires, 1)
    }

    // MARK: - Vendor slices

    func testSavingOneVendorsSliceKeepsTheOtherVendorsEntries() {
        HwKnownDeviceStorage.save(makeDevice(xpubs: ["nativeSegwit": "zTrezor"], walletId: "trezor:standard"))
        HwKnownDeviceStorage.save(makeJade(walletId: "jade:wallet"))

        HwKnownDeviceStorage.saveAll([], vendor: .trezor)

        XCTAssertEqual(HwKnownDeviceStorage.loadAll().compactMap(\.walletId), ["jade:wallet"])
    }

    func testLoadingAVendorsSliceReturnsOnlyItsEntries() {
        HwKnownDeviceStorage.save(makeDevice(xpubs: ["nativeSegwit": "zTrezor"], walletId: "trezor:standard"))
        HwKnownDeviceStorage.save(makeJade(walletId: "jade:wallet"))

        XCTAssertEqual(HwKnownDeviceStorage.loadAll(vendor: .trezor).compactMap(\.walletId), ["trezor:standard"])
        XCTAssertEqual(HwKnownDeviceStorage.loadAll(vendor: .blockstream).compactMap(\.walletId), ["jade:wallet"])
        XCTAssertEqual(Set(HwKnownDeviceStorage.loadAll().compactMap(\.walletId)), ["trezor:standard", "jade:wallet"])
    }

    /// Both vendors share a transport-level id here only to prove the removal stays inside its slice.
    func testRemovingByIdOnlyTouchesThatVendor() {
        HwKnownDeviceStorage.save(makeDevice(id: "shared", xpubs: ["nativeSegwit": "zTrezor"], walletId: "trezor:standard"))
        HwKnownDeviceStorage.save(makeJade(id: "shared", walletId: "jade:wallet"))

        HwKnownDeviceStorage.remove(id: "shared", vendor: .trezor)

        XCTAssertEqual(HwKnownDeviceStorage.loadAll().compactMap(\.walletId), ["jade:wallet"])
        XCTAssertFalse(HwKnownDeviceStorage.isKnown(id: "shared", vendor: .trezor))
        XCTAssertTrue(HwKnownDeviceStorage.isKnown(id: "shared", vendor: .blockstream))
        XCTAssertTrue(HwKnownDeviceStorage.isKnown(id: "shared"))
    }

    func testTheBackupSnapshotCoversEveryVendor() {
        HwKnownDeviceStorage.save(
            makeDevice(xpubs: ["nativeSegwit": "zTrezor"], customLabel: "Cold", walletId: "trezor:standard")
        )
        HwKnownDeviceStorage.save(makeJade(customLabel: "Travel", walletId: "jade:wallet"))
        HwKnownDeviceStorage.setPendingName(walletId: "jade:removed", name: "Old Jade")

        XCTAssertEqual(
            HwKnownDeviceStorage.backupSnapshot(),
            ["trezor:standard": "Cold", "jade:wallet": "Travel", "jade:removed": "Old Jade"]
        )
    }

    func testEntriesStoredBeforeVendorsExistedStayInTheTrezorSlice() throws {
        try storeRawEntries([legacyEntry(id: "dev1", walletId: "trezor:legacy")])

        XCTAssertEqual(HwKnownDeviceStorage.loadAll(vendor: .trezor).map(\.id), ["dev1"])
        XCTAssertTrue(HwKnownDeviceStorage.loadAll(vendor: .blockstream).isEmpty)
    }

    /// A newer build may pair a vendor this one does not know. Rolling back must neither show that
    /// wallet as another vendor's nor drop it on the next write.
    func testAnEntryOfAnUnknownVendorIsKeptOutOfEverySliceAndWrittenBack() throws {
        var foreign = legacyEntry(id: "passport1", walletId: "foundation:wallet")
        foreign["vendor"] = "foundation"
        try storeRawEntries([legacyEntry(id: "dev1", walletId: "trezor:standard"), foreign])

        XCTAssertEqual(HwKnownDeviceStorage.loadAll().map(\.id), ["dev1"])
        XCTAssertFalse(HwKnownDeviceStorage.isKnown(id: "passport1"))

        HwKnownDeviceStorage.saveAll([], vendor: .trezor)
        HwKnownDeviceStorage.save(makeJade(walletId: "jade:wallet"))
        HwKnownDeviceStorage.remove(walletId: "jade:wallet")

        XCTAssertTrue(HwKnownDeviceStorage.loadAll().isEmpty)
        let stored = try XCTUnwrap(UserDefaults.standard.data(forKey: Self.storageKey))
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [[String: Any]])
        XCTAssertEqual(entries.compactMap { $0["id"] as? String }, ["passport1"])
        XCTAssertEqual(entries.compactMap { $0["vendor"] as? String }, ["foundation"])
    }

    private func makeDevice(
        id: String = "dev1",
        xpubs: [String: String],
        customLabel: String? = nil,
        walletId: String? = nil,
        passphraseProtected: Bool = false,
        trezorDeviceId: String? = nil
    ) -> HwKnownDevice {
        HwKnownDevice(
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

    private func makeJade(
        id: String = "jade:bluetooth:aabbcc",
        customLabel: String? = nil,
        walletId: String
    ) -> HwKnownDevice {
        HwKnownDevice(
            id: id,
            name: "Jade AABBCC",
            path: "ble:jade",
            transportType: "bluetooth",
            model: "Jade",
            lastConnectedAt: Date(timeIntervalSince1970: 0),
            xpubs: ["nativeSegwit": "zJade"],
            customLabel: customLabel,
            walletId: walletId,
            vendor: .blockstream,
            jadeDeviceId: "aabbcc"
        )
    }

    /// An entry as a build without vendors wrote it: no `vendor` key at all.
    private func legacyEntry(id: String, walletId: String) -> [String: Any] {
        [
            "id": id,
            "name": "Device",
            "path": "ble://\(id)",
            "transportType": "bluetooth",
            "lastConnectedAt": 0,
            "xpubs": ["nativeSegwit": "z\(id)"],
            "walletId": walletId,
        ]
    }

    private func storeRawEntries(_ entries: [[String: Any]]) throws {
        try UserDefaults.standard.set(JSONSerialization.data(withJSONObject: entries), forKey: Self.storageKey)
    }
}
