@testable import Bitkit
import XCTest

/// The THP pairing credentials a Trezor reconnects with, which the keychain wipe misses as they are saved outside its access
/// group.
@MainActor
final class TrezorCredentialStorageTests: XCTestCase {
    private let deviceId = "AA:BB:CC:DD:EE:FF"

    override func setUp() {
        super.setUp()
        try? TrezorCredentialStorage.deleteAll()
    }

    override func tearDown() {
        try? TrezorCredentialStorage.deleteAll()
        super.tearDown()
    }

    // Regression: a wallet wipe kept the pairing credentials, so re-pairing skipped the code
    func testTheWipeKeychainStepRemovesThePairingCredentials() throws {
        XCTAssertTrue(TrezorCredentialStorage.save(deviceId: deviceId, json: #"{"host_static_key":"00"}"#))

        try AppReset.wipeKeychain()

        XCTAssertNil(TrezorCredentialStorage.load(deviceId: deviceId))
        XCTAssertTrue(TrezorCredentialStorage.listAllDeviceIds().isEmpty)
    }

    func testAFailedDeleteThrowsSoTheWipeStaysPending() {
        XCTAssertThrowsError(try TrezorCredentialStorage.deleteAll { _ in errSecInteractionNotAllowed }) { error in
            XCTAssertEqual(error as? Bitkit.KeychainError, .failedToDelete)
        }
    }

    func testDeletingWithNothingStoredSucceeds() {
        XCTAssertNoThrow(try TrezorCredentialStorage.deleteAll { _ in errSecItemNotFound })
    }
}
