@testable import Bitkit
import BitkitCore
import XCTest

/// Keys stored for a known Trezor must stay byte-identical across the bitkit-core 0.7.0 upgrade,
/// which normalized `TrezorPublicKeyResponse.xpub` and moved the firmware SLIP-132 form to `xpubSegwit`.
/// Fixtures are the BIP-44/49/84/86 test vectors for the "abandon ... about" mnemonic.
final class TrezorStoredAccountKeyTests: XCTestCase {
    private static let legacyXpub =
        "xpub6BosfCnifzxcFwrSzQiqu2DBVTshkCXacvNsWGYJVVhhawA7d4R5WSWGFNbi8Aw6ZRc1brxMyWMzG3DSSSSoekkudhUd9yLb6qx39T9nMdj"
    private static let nestedYpub =
        "ypub6Ww3ibxVfGzLrAH1PNcjyAWenMTbbAosGNB6VvmSEgytSER9azLDWCxoJwW7Ke7icmizBMXrzBx9979FfaHxHcrArf3zbeJJJUZPf663zsP"
    private static let nestedXpub =
        "xpub6C6nQwHaWbSrzs5tZ1q7m5R9cPK9eYpNMFesiXsYrgc1P8bvLLAet9JfHjYXKjToD8cBRswJXXbbFpXgwsswVPAZzKMa1jUp2kVkGVUaJa7"
    private static let nativeZpub =
        "zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs"
    private static let nativeXpub =
        "xpub6CatWdiZiodmUeTDp8LT5or8nmbKNcuyvz7WyksVFkKB4RHwCD3XyuvPEbvqAQY3rAPshWcMLoP2fMFMKHPJ4ZeZXYVUhLv1VMrjPC7PW6V"
    private static let taprootXpub =
        "xpub6BgBgsespWvERF3LHQu6CnqdvfEvtMcQjYrcRzx53QJjSxarj2afYWcLteoGVky7D3UKDP9QyrLprQ3VCECoY49yfdDEHGCtMMj92pReUsQ"
    private static let taprootDescriptor = "tr([73c5da0a/86'/0'/0']\(taprootXpub)/<0;1>/*)"

    /// Keys exactly as Core 0.5.18 (trezor-connect-rs 0.4.0) returned them in `xpub`.
    private static let storedBeforeUpgrade = [
        "legacy": legacyXpub,
        "nestedSegwit": nestedYpub,
        "nativeSegwit": nativeZpub,
        "taproot": taprootXpub,
    ]

    // MARK: - storedAccountKey(for:)

    func testSegwitTypesKeepTheFirmwareSlip132Key() {
        XCTAssertEqual(response(for: .nestedSegwit).storedAccountKey(for: .nestedSegwit), Self.nestedYpub)
        XCTAssertEqual(response(for: .nativeSegwit).storedAccountKey(for: .nativeSegwit), Self.nativeZpub)
    }

    func testLegacyKeepsTheXpub() {
        XCTAssertEqual(response(for: .legacy).storedAccountKey(for: .legacy), Self.legacyXpub)
    }

    func testTaprootNeverStoresTheDescriptor() {
        let taproot = response(for: .taproot)

        XCTAssertEqual(taproot.xpubSegwit, Self.taprootDescriptor)
        XCTAssertEqual(taproot.storedAccountKey(for: .taproot), Self.taprootXpub)
    }

    func testSegwitFallsBackToXpubWithoutASegwitForm() {
        let response = makeResponse(xpub: Self.nativeXpub, xpubSegwit: nil, path: "m/84'/0'/0'")

        XCTAssertEqual(response.storedAccountKey(for: .nativeSegwit), Self.nativeXpub)
    }

    // MARK: - Reconnect identity

    /// A device paired before the upgrade reconnects: the fetched keys must equal the stored ones,
    /// so matching, `walletKey` and the derived wallet id (for entries without a persisted id) hold.
    func testReconnectOfAPreviouslyPairedDeviceKeepsItsIdentity() throws {
        let stored = makeDevice(xpubs: Self.storedBeforeUpgrade)
        let fetched = Dictionary(uniqueKeysWithValues: AddressScriptType.allAddressTypes.map {
            ($0.stringValue, response(for: $0).storedAccountKey(for: $0))
        })

        let previous = HwKnownDeviceMatching.previous(in: [stored], deviceId: stored.id, fetchedXpubs: fetched)
        let mergedXpubs = (previous?.xpubs ?? [:]).merging(fetched) { _, new in new }
        let refreshed = makeDevice(xpubs: mergedXpubs)

        XCTAssertEqual(previous?.id, stored.id)
        XCTAssertEqual(mergedXpubs, Self.storedBeforeUpgrade)
        XCTAssertEqual(HwKnownDevice.walletKey(for: mergedXpubs, fallback: stored.id), stored.walletKey)
        XCTAssertEqual(try HwWalletId.derive(xpubs: mergedXpubs, vendor: .trezor), stored.resolvedWalletId)
        XCTAssertEqual(HwKnownDeviceMatching.merged([stored], with: refreshed, refreshed: previous).count, 1)
    }

    // MARK: - Helpers

    /// A response shaped like Core 0.7.0 returns it for the account of `addressType`.
    private func response(for addressType: AddressScriptType) -> TrezorPublicKeyResponse {
        switch addressType {
        case .legacy:
            makeResponse(xpub: Self.legacyXpub, xpubSegwit: nil, path: "m/44'/0'/0'")
        case .nestedSegwit:
            makeResponse(xpub: Self.nestedXpub, xpubSegwit: Self.nestedYpub, path: "m/49'/0'/0'")
        case .nativeSegwit:
            makeResponse(xpub: Self.nativeXpub, xpubSegwit: Self.nativeZpub, path: "m/84'/0'/0'")
        case .taproot:
            makeResponse(
                xpub: Self.taprootXpub,
                xpubSegwit: Self.taprootDescriptor,
                descriptor: Self.taprootDescriptor,
                displayablePublicKey: Self.taprootDescriptor,
                path: "m/86'/0'/0'"
            )
        }
    }

    private func makeResponse(
        xpub: String,
        xpubSegwit: String?,
        descriptor: String? = nil,
        displayablePublicKey: String? = nil,
        path: String
    ) -> TrezorPublicKeyResponse {
        TrezorPublicKeyResponse(
            xpub: xpub,
            xpubSegwit: xpubSegwit,
            descriptor: descriptor,
            displayablePublicKey: displayablePublicKey ?? xpubSegwit ?? xpub,
            path: path,
            publicKey: "02",
            chainCode: "00",
            fingerprint: 0,
            depth: 3,
            rootFingerprint: 0x73C5_DA0A
        )
    }

    private func makeDevice(xpubs: [String: String]) -> HwKnownDevice {
        HwKnownDevice(
            id: "dev1",
            name: "Trezor",
            path: "ble://dev1",
            transportType: "bluetooth",
            lastConnectedAt: Date(timeIntervalSince1970: 0),
            xpubs: xpubs,
            customLabel: nil,
            walletId: nil,
            passphraseProtected: false,
            trezorDeviceId: nil,
            vendor: .trezor,
            jadeDeviceId: nil
        )
    }
}
