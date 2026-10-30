@testable import Bitkit
import BitkitCore
import XCTest

/// Fixtures in `Fixtures/android-backup` are bitkit-android `BackupRepo` output, encoded by kotlinx.serialization.
final class AndroidBackupJsonTests: XCTestCase {
    func testAndroidActivityDecodesAfterNormalizing() throws {
        let data = try fixture("activity")
        XCTAssertThrowsError(try JSONDecoder().decode(ActivityBackupV1.self, from: data))

        let backup = try JSONDecoder().decode(ActivityBackupV1.self, from: AndroidBackupJson.normalized(data))

        guard case let .lightning(lightning) = backup.activities[0], case let .onchain(onchain) = backup.activities[1] else {
            return XCTFail("Unexpected activities \(backup.activities)")
        }
        XCTAssertEqual(lightning.txType, .sent)
        XCTAssertEqual(lightning.status, .succeeded)
        XCTAssertEqual(lightning.contact, "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw374y")
        XCTAssertEqual(onchain.txType, .received)
        XCTAssertNil(onchain.channelId)
        XCTAssertEqual(backup.activityTags.first?.tags, ["QA1164"])
    }

    func testAndroidBlocktankDecodesAfterNormalizing() throws {
        let data = try fixture("blocktank")
        XCTAssertThrowsError(try JSONDecoder().decode(BlocktankBackupV1.self, from: data))

        let backup = try JSONDecoder().decode(BlocktankBackupV1.self, from: AndroidBackupJson.normalized(data))

        XCTAssertEqual(backup.info?.onchain.network, .regtest)
        XCTAssertEqual(backup.orders.first?.state, .open)
        XCTAssertEqual(backup.orders.first?.state2, .executed)
        XCTAssertEqual(backup.orders.first?.channel?.state, .open)
        XCTAssertEqual(backup.cjitEntries.first?.state, .created)
    }

    func testIosEnvelopePassesThroughUnchanged() throws {
        let android = try JSONDecoder().decode(ActivityBackupV1.self, from: AndroidBackupJson.normalized(fixture("activity")))
        let ios = try JSONEncoder().encode(android)

        let backup = try JSONDecoder().decode(ActivityBackupV1.self, from: AndroidBackupJson.normalized(ios))

        XCTAssertEqual(backup.activities, android.activities)
    }

    func testAndroidMetadataDecodesAsIs() throws {
        let backup = try JSONDecoder().decode(MetadataBackupV1.self, from: fixture("metadata"))

        XCTAssertEqual(backup.pubkySession?.kind, .localSeed)
        XCTAssertNil(backup.tagMetadata.first?.txId)
        XCTAssertEqual(backup.pubkyContactProfileOverrides?.values.first?.name, "Contact Wallet")
    }

    func testAndroidSettingsKeepTheirValues() throws {
        let settings = try SettingsBackupV1.decode(from: fixture("settings")).settings

        XCTAssertEqual(
            SettingsViewModel.iosSettingString(settings["addressTypesToMonitor"] as Any, forKey: "addressTypesToMonitor"),
            "nativeSegwit,taproot"
        )
        XCTAssertEqual(SettingsViewModel.iosSettingString(settings["primaryDisplay"] as Any, forKey: "primaryDisplay"), "Fiat")
        XCTAssertEqual(SettingsViewModel.iosSettingString(settings["displayUnit"] as Any, forKey: "bitcoinDisplayUnit"), "classic")
    }

    func testAndroidMediumSpeedReadsAsNormal() {
        XCTAssertEqual(SettingsViewModel.iosSettingString("medium", forKey: "defaultTransactionSpeed"), "normal")
    }

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/android-backup/\(name).json")
        return try Data(contentsOf: url)
    }
}
