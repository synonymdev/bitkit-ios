@testable import Bitkit
import XCTest

/// Covers how a connect resolves which stored entry it refreshes and which entries it supersedes,
/// now that one physical device can hold a standard wallet plus its passphrase (hidden) wallets.
final class HwKnownDeviceMatchingTests: XCTestCase {
    // MARK: - previous(in:deviceId:fetchedXpubs:)

    func testRefreshesTheEntrySharingKeyMaterial() {
        let standard = makeDevice(xpubs: ["nativeSegwit": "zStandard"])
        let hidden = makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: "trezor:hidden")

        let previous = HwKnownDeviceMatching.previous(
            in: [standard, hidden],
            deviceId: "dev1",
            fetchedXpubs: ["nativeSegwit": "zHidden", "taproot": "zHiddenTR"]
        )

        XCTAssertEqual(previous?.walletId, "trezor:hidden")
    }

    /// A passphrase wallet read for the first time overlaps nothing, so it must not adopt the
    /// standard wallet's entry, since that would blend two seeds' xpubs into one record.
    func testTreatsUnseenKeyMaterialAsANewIdentity() {
        let standard = makeDevice(xpubs: ["nativeSegwit": "zStandard"])

        let previous = HwKnownDeviceMatching.previous(
            in: [standard],
            deviceId: "dev1",
            fetchedXpubs: ["nativeSegwit": "zHidden"]
        )

        XCTAssertNil(previous)
    }

    func testAdoptsALoneEntryStoredBeforeAnyXpubWasCaptured() {
        let bare = makeDevice(xpubs: [:], customLabel: "My Trezor")

        let previous = HwKnownDeviceMatching.previous(
            in: [bare],
            deviceId: "dev1",
            fetchedXpubs: ["nativeSegwit": "zStandard"]
        )

        XCTAssertEqual(previous?.customLabel, "My Trezor")
    }

    func testIgnoresEntriesOfAnotherDevice() {
        let other = makeDevice(id: "dev2", xpubs: ["nativeSegwit": "zStandard"])

        let previous = HwKnownDeviceMatching.previous(
            in: [other],
            deviceId: "dev1",
            fetchedXpubs: ["nativeSegwit": "zStandard"]
        )

        XCTAssertNil(previous)
    }

    // MARK: - named(in:previous:walletKey:)

    /// The wallet reappears on a fresh transport path, so nothing matches by device id, but it is
    /// the same key material, and the user's label belongs to the wallet, not to the path.
    func testInheritsTheLabelOfTheSameWalletOnAnotherPath() {
        let previouslyPaired = makeDevice(id: "old-path", xpubs: ["nativeSegwit": "zStandard"], customLabel: "Savings")

        let named = HwKnownDeviceMatching.named(
            in: [previouslyPaired],
            previous: nil,
            walletKey: HwKnownDevice.walletKey(for: ["nativeSegwit": "zStandard"], fallback: "dev1")
        )

        XCTAssertEqual(named?.customLabel, "Savings")
    }

    func testPrefersTheRefreshedEntryForTheLabel() {
        let refreshed = makeDevice(xpubs: ["nativeSegwit": "zStandard"], customLabel: "Refreshed")
        let sameKey = makeDevice(id: "old-path", xpubs: ["nativeSegwit": "zStandard"], customLabel: "Stale")

        let named = HwKnownDeviceMatching.named(
            in: [sameKey, refreshed],
            previous: refreshed,
            walletKey: refreshed.walletKey
        )

        XCTAssertEqual(named?.customLabel, "Refreshed")
    }

    // MARK: - merged(_:with:refreshed:)

    func testKeepsTheStandardWalletWhenAPassphraseWalletIsAdded() {
        let standard = makeDevice(xpubs: ["nativeSegwit": "zStandard"], walletId: "trezor:standard")
        let hidden = makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: "trezor:hidden", passphraseProtected: true)

        let merged = HwKnownDeviceMatching.merged([standard], with: hidden, refreshed: nil)

        XCTAssertEqual(merged.map(\.walletId), ["trezor:standard", "trezor:hidden"])
    }

    func testReplacesTheEntryHoldingTheSameIdentity() {
        let stored = makeDevice(xpubs: ["nativeSegwit": "zStandard"], customLabel: "Old")
        let known = makeDevice(xpubs: ["nativeSegwit": "zStandard"], customLabel: "New")

        let merged = HwKnownDeviceMatching.merged([stored], with: known, refreshed: stored)

        XCTAssertEqual(merged.map(\.customLabel), ["New"])
    }

    /// Reading a previously rejected address type changes the wallet key, so matching on the new
    /// key alone would leave the entry this connect refreshed behind as a duplicate.
    func testReplacesTheRefreshedEntryWhenReadingMoreAccountsChangesItsKey() {
        let partial = makeDevice(xpubs: ["nativeSegwit": "zStandard"])
        let complete = makeDevice(xpubs: ["nativeSegwit": "zStandard", "taproot": "zTaproot"])

        let merged = HwKnownDeviceMatching.merged([partial], with: complete, refreshed: partial)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].xpubs.count, 2)
    }

    func testSupersedesWalletsOfASeedTheDeviceNoLongerCarries() {
        let wiped = makeDevice(xpubs: ["nativeSegwit": "zOldSeed"], trezorDeviceId: "trezor-before-wipe")
        let known = makeDevice(xpubs: ["nativeSegwit": "zNewSeed"], trezorDeviceId: "trezor-after-wipe")

        let merged = HwKnownDeviceMatching.merged([wiped], with: known, refreshed: nil)

        XCTAssertEqual(merged.map(\.xpubs), [["nativeSegwit": "zNewSeed"]])
    }

    /// Two identities of one device report the same Trezor device id, so the wipe rule must not
    /// sweep away the sibling wallet.
    func testKeepsAnotherIdentityOfTheSameDevice() {
        let standard = makeDevice(
            xpubs: ["nativeSegwit": "zStandard"],
            walletId: "trezor:standard",
            trezorDeviceId: "trezor-id"
        )
        let hidden = makeDevice(
            xpubs: ["nativeSegwit": "zHidden"],
            walletId: "trezor:hidden",
            passphraseProtected: true,
            trezorDeviceId: "trezor-id"
        )

        let merged = HwKnownDeviceMatching.merged([standard], with: hidden, refreshed: nil)

        XCTAssertEqual(merged.map(\.walletId), ["trezor:standard", "trezor:hidden"])
    }

    func testLeavesEntriesOfAnotherDeviceAlone() {
        let other = makeDevice(id: "dev2", xpubs: ["nativeSegwit": "zOther"], trezorDeviceId: "other-trezor")
        let known = makeDevice(xpubs: ["nativeSegwit": "zStandard"], trezorDeviceId: "trezor-id")

        let merged = HwKnownDeviceMatching.merged([other], with: known, refreshed: nil)

        XCTAssertEqual(merged.count, 2)
    }

    // MARK: - Identity helpers

    func testWalletKeyIsIndependentOfAddressTypeKeys() {
        let a = makeDevice(xpubs: ["nativeSegwit": "zA", "taproot": "zB"])
        let b = makeDevice(xpubs: ["taproot": "zA", "nativeSegwit": "zB"])

        XCTAssertEqual(a.walletKey, b.walletKey)
    }

    func testWalletKeyFallsBackToTheTransportIdWithoutXpubs() {
        XCTAssertEqual(makeDevice(xpubs: [:]).walletKey, "dev1")
    }

    func testEntryIdSeparatesTwoIdentitiesOfOneDevice() {
        let standard = makeDevice(xpubs: ["nativeSegwit": "zStandard"])
        let hidden = makeDevice(xpubs: ["nativeSegwit": "zHidden"])

        XCTAssertNotEqual(standard.entryId, hidden.entryId)
    }

    func testResolvedWalletIdPrefersTheStoredValue() {
        let device = makeDevice(xpubs: ["nativeSegwit": "zStandard"], walletId: "trezor:stored")

        XCTAssertEqual(device.resolvedWalletId, "trezor:stored")
    }

    // MARK: - Decoding entries stored before hidden wallets existed

    func testDecodesLegacyEntriesAndDerivesTheirWalletId() throws {
        let legacy = """
        {
            "id": "dev1",
            "name": "Trezor",
            "path": "ble://dev1",
            "transportType": "bluetooth",
            "lastConnectedAt": 0,
            "xpubs": { "nativeSegwit": "zStandard" }
        }
        """

        let decoded = try JSONDecoder().decode(HwKnownDevice.self, from: Data(legacy.utf8))

        XCTAssertNil(decoded.walletId)
        XCTAssertFalse(decoded.passphraseProtected)
        XCTAssertNil(decoded.trezorDeviceId)
        XCTAssertEqual(decoded.resolvedWalletId, try HwWalletId.derive(xpubs: ["nativeSegwit": "zStandard"]))
    }

    // MARK: - Vendors

    func testDecodesLegacyEntriesAsTrezor() throws {
        let decoded = try decode(legacyJson(id: "dev1", walletId: "trezor:standard"))

        XCTAssertEqual(decoded.vendor, .trezor)
        XCTAssertTrue(decoded.belongs(to: .trezor))
        XCTAssertNil(decoded.jadeDeviceId)
        XCTAssertNil(decoded.hardwareId)
    }

    func testInfersJadeForALegacyEntryInTheJadeNamespace() throws {
        XCTAssertEqual(try decode(legacyJson(id: "jade:bluetooth:aabbcc", walletId: nil)).vendor, .blockstream)
        XCTAssertEqual(try decode(legacyJson(id: "dev1", walletId: "jade:wallet")).vendor, .blockstream)
    }

    func testAJadeEntrySurvivesARoundTrip() throws {
        let jade = makeDevice(
            id: "jade:bluetooth:aabbcc",
            xpubs: ["nativeSegwit": "zJade"],
            customLabel: "Travel",
            walletId: "jade:wallet",
            vendor: .blockstream,
            jadeDeviceId: "aabbcc"
        )

        let decoded = try JSONDecoder().decode(HwKnownDevice.self, from: JSONEncoder().encode(jade))

        XCTAssertEqual(decoded, jade)
        XCTAssertEqual(decoded.vendor, .blockstream)
        XCTAssertEqual(decoded.hardwareId, "aabbcc")
    }

    /// A newer build may store a vendor this one does not know. Decoding it must not fail the whole
    /// device list, and writing it back must keep the vendor it was stored under.
    func testAnUnknownVendorIsWrittenBackUnchanged() throws {
        let decoded = try decode(legacyJson(id: "passport1", walletId: "foundation:wallet", vendor: "foundation"))

        XCTAssertEqual(decoded.unknownVendor, "foundation")
        XCTAssertFalse(HwWalletVendor.allCases.contains(where: decoded.belongs(to:)))

        let reencoded = try JSONEncoder().encode(decoded.refreshed(path: "ble://moved", at: Date(timeIntervalSince1970: 5)))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        XCTAssertEqual(json["vendor"] as? String, "foundation")
    }

    func testADeviceOfAnotherVendorNeverReplacesAnEntry() {
        let trezor = makeDevice(id: "shared", xpubs: ["nativeSegwit": "zShared"], walletId: "trezor:wallet")
        let jade = makeDevice(
            id: "shared",
            xpubs: ["nativeSegwit": "zShared"],
            walletId: "jade:wallet",
            vendor: .blockstream,
            jadeDeviceId: "aabbcc"
        )

        let merged = HwKnownDeviceMatching.merged([trezor], with: jade, refreshed: nil)

        XCTAssertEqual(merged.map(\.walletId), ["trezor:wallet", "jade:wallet"])
    }

    func testAJadeEntryIsSupersededByADifferentJadeDeviceId() {
        let wiped = makeDevice(
            id: "jade:bluetooth:aabbcc",
            xpubs: ["nativeSegwit": "zOldSeed"],
            vendor: .blockstream,
            jadeDeviceId: "aabbcc"
        )
        let known = makeDevice(
            id: "jade:bluetooth:aabbcc",
            xpubs: ["nativeSegwit": "zNewSeed"],
            vendor: .blockstream,
            jadeDeviceId: "ddeeff"
        )

        let merged = HwKnownDeviceMatching.merged([wiped], with: known, refreshed: nil)

        XCTAssertEqual(merged.map(\.xpubs), [["nativeSegwit": "zNewSeed"]])
    }

    func testAJadeEntryIsReplacedByAReReadOfTheSameHardwareWithMoreKeys() {
        let stored = makeDevice(
            id: "jade:bluetooth:aabbcc",
            path: "ble:old",
            xpubs: ["nativeSegwit": "zJade"],
            vendor: .blockstream,
            jadeDeviceId: "aabbcc"
        )
        let reread = makeDevice(
            id: "jade:bluetooth:aabbcc",
            path: "ble:new",
            xpubs: ["nativeSegwit": "zJade", "taproot": "zJadeTR"],
            vendor: .blockstream,
            jadeDeviceId: "aabbcc"
        )

        let merged = HwKnownDeviceMatching.merged([stored], with: reread, refreshed: stored)

        XCTAssertEqual(merged.map(\.path), ["ble:new"])
        XCTAssertEqual(merged.first?.xpubs.count, 2)
    }

    func testAJadeEntryWithoutAStoredIdDerivesAJadeWalletId() throws {
        let jade = makeDevice(xpubs: ["nativeSegwit": "zJade"], vendor: .blockstream)

        let walletId = try XCTUnwrap(jade.resolvedWalletId)

        XCTAssertTrue(walletId.hasPrefix("jade:"))
        XCTAssertEqual(walletId, try HwWalletId.derive(xpubs: ["nativeSegwit": "zJade"], vendor: .blockstream))
    }

    func testRefreshingAnEntryOnlyMovesItsPathAndTime() {
        let stored = makeDevice(
            id: "jade:bluetooth:aabbcc",
            path: "ble:old",
            xpubs: ["nativeSegwit": "zJade"],
            customLabel: "Travel",
            walletId: "jade:wallet",
            vendor: .blockstream,
            jadeDeviceId: "aabbcc"
        )

        let refreshed = stored.refreshed(path: "ble:new", at: Date(timeIntervalSince1970: 50))

        XCTAssertEqual(refreshed.path, "ble:new")
        XCTAssertEqual(refreshed.lastConnectedAt, Date(timeIntervalSince1970: 50))
        XCTAssertEqual(refreshed.entryId, stored.entryId)
        XCTAssertEqual(refreshed.customLabel, "Travel")
        XCTAssertEqual(refreshed.resolvedWalletId, "jade:wallet")
        XCTAssertEqual(refreshed.vendor, .blockstream)
        XCTAssertEqual(refreshed.hardwareId, "aabbcc")
    }

    private func makeDevice(
        id: String = "dev1",
        path: String? = nil,
        xpubs: [String: String],
        customLabel: String? = nil,
        walletId: String? = nil,
        passphraseProtected: Bool = false,
        trezorDeviceId: String? = nil,
        vendor: HwWalletVendor = .trezor,
        jadeDeviceId: String? = nil
    ) -> HwKnownDevice {
        HwKnownDevice(
            id: id,
            name: vendor == .trezor ? "Trezor" : "Jade",
            path: path ?? "ble://\(id)",
            transportType: "bluetooth",
            lastConnectedAt: Date(timeIntervalSince1970: 0),
            xpubs: xpubs,
            customLabel: customLabel,
            walletId: walletId,
            passphraseProtected: passphraseProtected,
            trezorDeviceId: trezorDeviceId,
            vendor: vendor,
            jadeDeviceId: jadeDeviceId
        )
    }

    private func legacyJson(id: String, walletId: String?, vendor: String? = nil) -> String {
        let walletIdField = walletId.map { ", \"walletId\": \"\($0)\"" } ?? ""
        let vendorField = vendor.map { ", \"vendor\": \"\($0)\"" } ?? ""
        return """
        {
            "id": "\(id)",
            "name": "Device",
            "path": "ble://\(id)",
            "transportType": "bluetooth",
            "lastConnectedAt": 0,
            "xpubs": { "nativeSegwit": "zStandard" }\(walletIdField)\(vendorField)
        }
        """
    }

    private func decode(_ json: String) throws -> HwKnownDevice {
        try JSONDecoder().decode(HwKnownDevice.self, from: Data(json.utf8))
    }
}
