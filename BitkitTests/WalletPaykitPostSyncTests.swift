@testable import Bitkit
import XCTest

@MainActor
final class WalletPaykitPostSyncTests: XCTestCase {
    private var wallet: WalletViewModel!
    private var gate: PassGate!
    private var passCount = 0

    override func setUp() async throws {
        wallet = WalletViewModel()
        gate = PassGate()
        passCount = 0
        wallet.paykitPostSyncOperationForTesting = { [unowned self] _ in
            passCount += 1
            await gate.wait()
        }
    }

    override func tearDown() async throws {
        gate.releaseAll()
        wallet.paykitPostSyncOperationForTesting = nil
        wallet = nil
    }

    func testSyncsDuringARunningPassQueueOneMorePass() async {
        wallet.schedulePaykitPostSync(isSessionCurrent: { true })
        await waitUntil { self.passCount == 1 }

        wallet.schedulePaykitPostSync(isSessionCurrent: { true })
        wallet.schedulePaykitPostSync(isSessionCurrent: { true })
        XCTAssertEqual(passCount, 1)

        gate.release()
        await waitUntil { self.passCount == 2 }
        gate.release()
        await wallet.waitForPaykitPostSync()

        XCTAssertEqual(passCount, 2)
    }

    func testWaitForPaykitPostSyncWaitsForTheQueuedPass() async {
        wallet.schedulePaykitPostSync(isSessionCurrent: { true })
        await waitUntil { self.passCount == 1 }
        wallet.schedulePaykitPostSync(isSessionCurrent: { true })

        var isWaitFinished = false
        let waiter = Task { @MainActor in
            await self.wallet.waitForPaykitPostSync()
            isWaitFinished = true
        }

        gate.release()
        await waitUntil { self.passCount == 2 }
        XCTAssertFalse(isWaitFinished)

        gate.release()
        await waiter.value
        XCTAssertTrue(isWaitFinished)
        XCTAssertEqual(passCount, 2)
    }

    func testWipeDropsQueuedPassAndBlocksNewPasses() async {
        wallet.schedulePaykitPostSync(isSessionCurrent: { true })
        await waitUntil { self.passCount == 1 }
        wallet.schedulePaykitPostSync(isSessionCurrent: { true })

        wallet.closeStartAdmissionForWipe()
        gate.open()
        wallet.schedulePaykitPostSync(isSessionCurrent: { true })
        await wallet.waitForPaykitPostSync()
        await Task.yield()

        XCTAssertEqual(passCount, 1)
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "condition not met within \(timeout)")
    }
}

@MainActor
private final class PassGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releasedCount = 0
    private var isOpen = false

    func wait() async {
        if isOpen {
            return
        }
        if releasedCount > 0 {
            releasedCount -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            releasedCount += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Lets every current and later pass finish at once, so a pass that should not run fails the test instead of hanging it.
    func open() {
        isOpen = true
        releaseAll()
    }

    func releaseAll() {
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
