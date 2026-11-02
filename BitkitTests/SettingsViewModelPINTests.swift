@testable import Bitkit
import XCTest

@MainActor
final class SettingsViewModelPINTests: XCTestCase {
    private struct KeychainFailure: Error {}

    func testPinWhosePresenceCannotBeReadCountsAsSet() {
        XCTAssertTrue(SettingsViewModel.isPinRequired { throw KeychainFailure() })
        XCTAssertTrue(SettingsViewModel.isPinRequired { true })
        XCTAssertFalse(SettingsViewModel.isPinRequired { false })
    }

    func testRestoreResetKeepsAStoredPinRequired() throws {
        snapshotAppDefaults("requirePinForPayments", "useBiometrics")
        let settings = SettingsViewModel.shared
        try Keychain.delete(key: .securityPin)
        try Keychain.saveString(key: .securityPin, str: "1234")
        addTeardownBlock { @MainActor in
            try? Keychain.delete(key: .securityPin)
            settings.updatePinEnabledState()
        }
        settings.updatePinEnabledState()

        settings.resetPinSettings()

        XCTAssertTrue(settings.pinEnabled)
        XCTAssertFalse(settings.requirePinForPayments)
        XCTAssertFalse(settings.useBiometrics)
    }

    func testPinErrorMessages() {
        XCTAssertEqual(PinResult.incorrect(remaining: 1).errorIdentifier, "LastAttempt")
        XCTAssertEqual(PinResult.incorrect(remaining: 1).errorMessage, t("security__pin_last_attempt"))
        XCTAssertEqual(PinResult.incorrect(remaining: 3).errorIdentifier, "AttemptsRemaining")
        XCTAssertEqual(
            PinResult.incorrect(remaining: 3).errorMessage,
            t("security__pin_attempts", variables: ["attemptsRemaining": "3"])
        )
        XCTAssertEqual(PinResult.unavailable.errorMessage, t("security__pin_unavailable"))
        XCTAssertNil(PinResult.unavailable.errorIdentifier)
        XCTAssertNil(PinResult.lockedOut.errorMessage)
        XCTAssertNil(PinResult.correct.errorMessage)
    }
}
