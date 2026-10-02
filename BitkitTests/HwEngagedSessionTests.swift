@testable import Bitkit
import XCTest

/// Ports Android `HwReceiveViewModelTest`'s session rules: the receive sheet releases only a device
/// session it engaged by verifying an address or entering a passphrase.
@MainActor
final class HwEngagedSessionTests: XCTestCase {
    private let walletId = "trezor:wallet"
    private let otherWalletId = "jade:wallet"

    private var releaser: RecordingSessionReleaser!
    private var session: HwEngagedSession!

    override func setUp() async throws {
        releaser = RecordingSessionReleaser()
        session = HwEngagedSession()
    }

    func testCancelWithoutUsingTheDeviceKeepsItsSession() {
        session.release(through: releaser)

        XCTAssertEqual(releaser.releasedWalletIds, [])
        XCTAssertNil(session.walletId)
    }

    func testCancelAfterVerificationClosesTheSession() async {
        await session.perform(walletId: walletId) {}

        session.release(through: releaser)

        XCTAssertEqual(releaser.releasedWalletIds, [walletId])
        XCTAssertNil(session.walletId)
    }

    func testCancelAfterAFailedVerificationStillClosesTheSession() async {
        do {
            try await session.perform(walletId: walletId) { throw CancellationError() }
            XCTFail("Expected the verification to fail")
        } catch {}

        session.release(through: releaser)

        XCTAssertEqual(releaser.releasedWalletIds, [walletId])
    }

    func testCancelDuringVerificationClosesTheSession() async {
        let gate = AsyncGate()
        let verification = Task { await session.perform(walletId: walletId) { await gate.wait() } }
        await waitUntil { self.session.isWorking }

        session.release(through: releaser)
        gate.open()
        await verification.value
        session.release(through: releaser)

        XCTAssertEqual(releaser.releasedWalletIds, [walletId])
        XCTAssertFalse(session.isWorking)
        XCTAssertNil(session.walletId)
    }

    func testWatcherAddressChangeKeepsASessionTheSheetNeverUsed() {
        session.invalidate(through: releaser)

        XCTAssertEqual(releaser.releasedWalletIds, [])
    }

    func testSelectedWalletChangeDuringVerificationReleasesTheSession() async {
        let gate = AsyncGate()
        let verification = Task { await session.perform(walletId: walletId) { await gate.wait() } }
        await waitUntil { self.session.isWorking }

        session.invalidate(through: releaser)
        gate.open()
        await verification.value
        session.release(through: releaser)

        XCTAssertEqual(releaser.releasedWalletIds, [walletId])
    }

    func testAddressChangeAfterVerificationKeepsTheSessionUntilTheSheetIsLeft() async {
        await session.perform(walletId: walletId) {}

        session.invalidate(through: releaser)
        XCTAssertEqual(releaser.releasedWalletIds, [])

        session.release(through: releaser)
        XCTAssertEqual(releaser.releasedWalletIds, [walletId])
    }

    func testReleasesTheWalletTheLatestWorkEngaged() async {
        await session.perform(walletId: walletId) {}
        await session.perform(walletId: otherWalletId) {}

        session.release(through: releaser)

        XCTAssertEqual(releaser.releasedWalletIds, [otherWalletId])
    }

    func testPassphraseWorkThatVerifiesEngagesTheSessionOnce() async {
        await session.perform(walletId: walletId) {
            await session.perform(walletId: walletId) {}
            XCTAssertTrue(session.isWorking)
        }
        XCTAssertFalse(session.isWorking)

        session.release(through: releaser)
        session.release(through: releaser)

        XCTAssertEqual(releaser.releasedWalletIds, [walletId])
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for condition")
    }
}

@MainActor
private final class RecordingSessionReleaser: HwSessionReleasing {
    private(set) var releasedWalletIds: [String] = []

    func scheduleStaleSessionCleanup(walletId: String) {
        releasedWalletIds.append(walletId)
    }
}
