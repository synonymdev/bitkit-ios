@testable import Bitkit
import XCTest

/// Covers how a connect resolves which stored entry it refreshes and which entries it supersedes,
/// now that one physical device can hold a standard wallet plus its passphrase (hidden) wallets.
final class TrezorKnownDeviceMatchingTests: XCTestCase {
    // MARK: - previous(in:deviceId:fetchedXpubs:)

    func testRefreshesTheEntrySharingKeyMaterial() {
        let standard = makeDevice(xpubs: ["nativeSegwit": "zStandard"])
        let hidden = makeDevice(xpubs: ["nativeSegwit": "zHidden"], walletId: "trezor:hidden")

        let previous = TrezorKnownDeviceMatching.previous(
            in: [standard, hidden],
            deviceId: "dev1",
            fetchedXpubs: ["nativeSegwit": "zHidden", "taproot": "zHiddenTR"]
        )

        XCTAssertEqual(previous?.walletId, "trezor:hidden")
    }

    /// A passphrase wallet read for the first time overlaps nothing, so it must not adopt the
    /// standard wallet's entry — that would blend two seeds' xpubs into one record.
    func testTreatsUnseenKeyMaterialAsANewIdentity() {
        let standard = makeDevice(xpubs: ["nativeSegwit": "zStandard"])

        let previous = TrezorKnownDeviceMatching.previous(
            in: [standard],
            deviceId: "dev1",
            fetchedXpubs: ["nativeSegwit": "zHidden"]
        )

        XCTAssertNil(previous)
    }

    func testAdoptsALoneEntryStoredBeforeAnyXpubWasCaptured() {
        let bare = makeDevice(xpubs: [:], customLabel: "My Trezor")

        let previous = TrezorKnownDeviceMatching.previous(
            in: [bare],
            deviceId: "dev1",
            fetchedXpubs: ["nativeSegwit": "zStandard"]
        )

        XCTAssertEqual(previous?.customLabel, "My Trezor")
    }

    func testIgnoresEntriesOfAnotherDevice() {
        let other = makeDevice(id: "dev2", xpubs: ["nativeSegwit": "zStandard"])

        let previous = TrezorKnownDeviceMatching.previous(
            in: [other],
            deviceId: "dev1",
            fetchedXpubs: ["nativeSegwit": "zStandard"]
        )

        XCTAssertNil(previous)
    }

    // MARK: - named(in:previous:walletKey:)

    /// The wallet reappears on a fresh transport path, so nothing matches by device id — but it is
    /// the same key material, and the user's label belongs to the wallet, not to the path.
    func testInheritsTheLabelOfTheSameWalletOnAnotherPath() {
        let previouslyPaired = makeDevice(id: "old-path", xpubs: ["nativeSegwit": "zStandard"], customLabel: "Savings")

        let named = TrezorKnownDeviceMatching.named(
            in: [previouslyPaired],
            previous: nil,
            walletKey: TrezorKnownDevice.walletKey(for: ["nativeSegwit": "zStandard"], fallback: "dev1")
        )

        XCTAssertEqual(named?.customLabel, "Savings")
    }

    func testPrefersTheRefreshedEntryForTheLabel() {
        let refreshed = makeDevice(xpubs: ["nativeSegwit": "zStandard"], customLabel: "Refreshed")
        let sameKey = makeDevice(id: "old-path", xpubs: ["nativeSegwit": "zStandard"], customLabel: "Stale")

        let named = TrezorKnownDeviceMatching.named(
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

        let merged = TrezorKnownDeviceMatching.merged([standard], with: hidden, refreshed: nil)

        XCTAssertEqual(merged.map(\.walletId), ["trezor:standard", "trezor:hidden"])
    }

    func testReplacesTheEntryHoldingTheSameIdentity() {
        let stored = makeDevice(xpubs: ["nativeSegwit": "zStandard"], customLabel: "Old")
        let known = makeDevice(xpubs: ["nativeSegwit": "zStandard"], customLabel: "New")

        let merged = TrezorKnownDeviceMatching.merged([stored], with: known, refreshed: stored)

        XCTAssertEqual(merged.map(\.customLabel), ["New"])
    }

    /// Reading a previously rejected address type changes the wallet key, so matching on the new
    /// key alone would leave the entry this connect refreshed behind as a duplicate.
    func testReplacesTheRefreshedEntryWhenReadingMoreAccountsChangesItsKey() {
        let partial = makeDevice(xpubs: ["nativeSegwit": "zStandard"])
        let complete = makeDevice(xpubs: ["nativeSegwit": "zStandard", "taproot": "zTaproot"])

        let merged = TrezorKnownDeviceMatching.merged([partial], with: complete, refreshed: partial)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].xpubs.count, 2)
    }

    func testSupersedesWalletsOfASeedTheDeviceNoLongerCarries() {
        let wiped = makeDevice(xpubs: ["nativeSegwit": "zOldSeed"], trezorDeviceId: "trezor-before-wipe")
        let known = makeDevice(xpubs: ["nativeSegwit": "zNewSeed"], trezorDeviceId: "trezor-after-wipe")

        let merged = TrezorKnownDeviceMatching.merged([wiped], with: known, refreshed: nil)

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

        let merged = TrezorKnownDeviceMatching.merged([standard], with: hidden, refreshed: nil)

        XCTAssertEqual(merged.map(\.walletId), ["trezor:standard", "trezor:hidden"])
    }

    func testLeavesEntriesOfAnotherDeviceAlone() {
        let other = makeDevice(id: "dev2", xpubs: ["nativeSegwit": "zOther"], trezorDeviceId: "other-trezor")
        let known = makeDevice(xpubs: ["nativeSegwit": "zStandard"], trezorDeviceId: "trezor-id")

        let merged = TrezorKnownDeviceMatching.merged([other], with: known, refreshed: nil)

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

        let decoded = try JSONDecoder().decode(TrezorKnownDevice.self, from: Data(legacy.utf8))

        XCTAssertNil(decoded.walletId)
        XCTAssertFalse(decoded.passphraseProtected)
        XCTAssertNil(decoded.trezorDeviceId)
        XCTAssertEqual(decoded.resolvedWalletId, try HwWalletId.derive(xpubs: ["nativeSegwit": "zStandard"]))
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
