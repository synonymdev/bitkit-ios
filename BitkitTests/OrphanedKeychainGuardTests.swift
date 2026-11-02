@testable import Bitkit
import XCTest

/// How a launch handles a keychain left behind by an uninstalled copy of the app, when its wipe fails.
final class OrphanedKeychainGuardTests: XCTestCase {
    private struct ProbeFailure: Error {}

    private final class Harness {
        var hasMarker = false
        var hasNativeMnemonic = false
        var isNativeMnemonicReadFailing = false
        var hasWalletStorage = false
        var hasOrphanedRNKeychain = false
        var hasRNMnemonic = false
        var isWipeFailing = false
        /// The wipe deletes the seeds, then fails on another item.
        var isWipeFailingAfterSeeds = false
        var isRNRemovalFailing = false
        private(set) var markerWrites = 0
        private(set) var keychainWipes = 0
        private(set) var rnKeychainRemovals = 0

        var guardUnderTest: OrphanedKeychainGuard {
            OrphanedKeychainGuard(
                hasInstallationMarker: { self.hasMarker },
                createInstallationMarker: {
                    self.markerWrites += 1
                    self.hasMarker = true
                },
                hasNativeMnemonic: {
                    if self.isNativeMnemonicReadFailing { throw ProbeFailure() }
                    return self.hasNativeMnemonic
                },
                hasWalletStorage: { self.hasWalletStorage },
                hasOrphanedRNKeychain: { self.hasOrphanedRNKeychain },
                hasRNMnemonic: { self.hasRNMnemonic },
                wipeKeychain: {
                    self.keychainWipes += 1
                    guard !self.isWipeFailing else { throw ProbeFailure() }
                    self.hasNativeMnemonic = false
                    if self.isWipeFailingAfterSeeds {
                        // The wipe deletes only this app's own access group, never an RN seed
                        throw ProbeFailure()
                    }
                },
                removeRNKeychain: {
                    self.rnKeychainRemovals += 1
                    if !self.isRNRemovalFailing {
                        self.hasRNMnemonic = false
                    }
                }
            )
        }
    }

    func testAnExistingMarkerSkipsTheCheck() throws {
        let harness = Harness()
        harness.hasMarker = true
        harness.hasNativeMnemonic = true

        try harness.guardUnderTest.run()

        XCTAssertEqual(harness.keychainWipes, 0)
        XCTAssertEqual(harness.markerWrites, 0)
    }

    func testAnUnreadableKeychainWritesNoMarkerSoTheNextLaunchChecksAgain() throws {
        let harness = Harness()
        harness.isNativeMnemonicReadFailing = true

        try harness.guardUnderTest.run()

        XCTAssertEqual(harness.keychainWipes, 0)
        XCTAssertEqual(harness.markerWrites, 0)
    }

    func testAnOrphanedKeychainIsWipedAndTheMarkerWritten() throws {
        let harness = Harness()
        harness.hasNativeMnemonic = true
        harness.hasOrphanedRNKeychain = true
        harness.hasRNMnemonic = true

        try harness.guardUnderTest.run()

        XCTAssertEqual(harness.keychainWipes, 1)
        XCTAssertEqual(harness.rnKeychainRemovals, 1)
        XCTAssertTrue(harness.hasMarker)
    }

    // Regression: a failed wipe let the launch go on, so a node set up on the leftover seed made it look like this install's
    func testAWipeThatFailsWithASeedLeftHoldsTheLaunchUntilARetryWipes() throws {
        let harness = Harness()
        harness.hasNativeMnemonic = true
        harness.isWipeFailing = true

        XCTAssertThrowsError(try harness.guardUnderTest.run()) { error in
            XCTAssertTrue(error is OrphanedKeychainGuard.WipeFailed, "Expected the launch to be held, got \(error)")
        }
        XCTAssertEqual(harness.markerWrites, 0, "Without the marker the next launch checks again")

        harness.isWipeFailing = false
        try harness.guardUnderTest.run()

        XCTAssertEqual(harness.keychainWipes, 2)
        XCTAssertTrue(harness.hasMarker)
    }

    func testAKeychainThatCannotBeReadAfterAFailedWipeHoldsTheLaunch() {
        let harness = Harness()
        harness.hasNativeMnemonic = true
        harness.isWipeFailing = true
        var reads = 0
        let base = harness.guardUnderTest
        var guardUnderTest = base
        guardUnderTest.hasNativeMnemonic = {
            reads += 1
            if reads > 1 { throw ProbeFailure() }
            return true
        }

        XCTAssertThrowsError(try guardUnderTest.run()) { error in
            XCTAssertTrue(error is OrphanedKeychainGuard.WipeFailed, "Expected the launch to be held, got \(error)")
        }
    }

    func testAFailureAfterTheSeedsNeedsNoHold() throws {
        let harness = Harness()
        harness.hasNativeMnemonic = true
        harness.isWipeFailingAfterSeeds = true

        try harness.guardUnderTest.run()

        XCTAssertTrue(harness.hasMarker)
    }

    func testAWipeThatFailsWithAnRNSeedItsRemovalCannotDeleteHoldsTheLaunch() {
        let harness = Harness()
        harness.hasOrphanedRNKeychain = true
        harness.hasRNMnemonic = true
        harness.isWipeFailing = true
        harness.isRNRemovalFailing = true

        XCTAssertThrowsError(try harness.guardUnderTest.run()) { error in
            XCTAssertTrue(error is OrphanedKeychainGuard.WipeFailed, "Expected the launch to be held, got \(error)")
        }
        XCTAssertEqual(harness.markerWrites, 0)
    }

    // Regression: an RN seed the wipe cannot reach, in another access group or synchronizable, held every launch of a
    // reinstall, as only its own removal deletes it and that ran only after a successful wipe
    func testAnRNSeedTheWipeCannotDeleteNoLongerHoldsAFreshInstall() throws {
        let harness = Harness()
        harness.hasOrphanedRNKeychain = true
        harness.hasRNMnemonic = true
        harness.isWipeFailing = true

        try harness.guardUnderTest.run()

        XCTAssertEqual(harness.rnKeychainRemovals, 1)
        XCTAssertFalse(harness.hasRNMnemonic)
        XCTAssertTrue(harness.hasMarker)
    }

    func testAFailedWipeNeverRemovesTheRNKeychainBesideTheWalletStoredHere() {
        let harness = Harness()
        harness.hasOrphanedRNKeychain = true
        harness.hasRNMnemonic = true
        harness.hasWalletStorage = true
        harness.isWipeFailing = true

        XCTAssertThrowsError(try harness.guardUnderTest.run())
        XCTAssertEqual(harness.rnKeychainRemovals, 0)
        XCTAssertEqual(harness.markerWrites, 0)
    }
}
