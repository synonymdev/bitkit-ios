@testable import Bitkit
import XCTest

@MainActor
final class AppResetTests: XCTestCase {
    func testRemoteCleanupThatIgnoresCancellationDoesNotHoldTheWipe() async {
        let started = ContinuousClock.now

        await AppReset.runRemoteCleanup(timeout: .milliseconds(50)) {
            await Task.detached { try? await Task.sleep(for: .seconds(3)) }.value
        }

        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }

    func testRemoteCleanupThatFinishesInTimeRuns() async {
        var didRun = false

        await AppReset.runRemoteCleanup(timeout: .seconds(5)) {
            didRun = true
        }

        XCTAssertTrue(didRun)
    }

    func testPrivateEndpointRemovalTheWipeStoppedWaitingForRecordsNoPendingCleanup() async {
        snapshotAppDefaults(PublicPaykitService.cleanupPendingKey, PrivatePaykitService.cleanupPendingKey)
        PublicPaykitService.setCleanupPending(false)
        PrivatePaykitService.setContactSharingCleanupPending(false)

        let removal = Task { await PubkyProfileManager.removePrivatePaykitEndpointsForWipe(context: "AppResetTests") }
        removal.cancel()
        await removal.value

        XCTAssertFalse(PublicPaykitService.isCleanupPending)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: PrivatePaykitService.cleanupPendingKey))
    }

    func testABoundedWaitThatRunsOverFailsTheStep() async {
        let started = ContinuousClock.now

        await assertThrowsAsync {
            try await AppReset.bounded("test", timeout: .milliseconds(50)) {
                await Task.detached { try? await Task.sleep(for: .seconds(3)) }.value
            }
        }

        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }

    func testTheKeychainStepKeepsThePinItsCounterAndTheIntent() throws {
        let kept: [KeychainEntryType] = [.securityPin, .pinFailedAttempts, .wipePending]
        addTeardownBlock {
            for key in kept + [.bip39Mnemonic(index: 0)] {
                try? Keychain.delete(key: key)
            }
        }
        for key in kept {
            try Keychain.upsert(key: key, data: Data("kept".utf8))
        }
        try Keychain.upsert(key: .bip39Mnemonic(index: 0), data: Data("seed".utf8))

        try AppReset.wipeKeychain()

        for key in kept {
            XCTAssertEqual(try Keychain.loadString(key: key), "kept", "\(key.storageKey) must outlive the keychain step")
        }
        XCTAssertNil(try Keychain.loadString(key: .bip39Mnemonic(index: 0)))
    }
}
