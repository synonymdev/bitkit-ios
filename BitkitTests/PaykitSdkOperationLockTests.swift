@testable import Bitkit
import Paykit
import XCTest

final class PaykitSdkOperationLockTests: XCTestCase {
    private actor Recorder {
        private(set) var events: [String] = []

        func record(_ event: String) {
            events.append(event)
        }
    }

    func testWipeDrainsActiveWorkRejectsQueuedWorkAndAllowsCleanupAndFreshWork() async throws {
        let lock = PaykitSdkOperationLock()
        let recorder = Recorder()
        let (activeGate, releaseActive) = AsyncStream<Void>.makeStream()
        let (activeStarted, startActive) = AsyncStream<Void>.makeStream()
        let (wipeGate, releaseWipe) = AsyncStream<Void>.makeStream()
        let (wipeStarted, startWipe) = AsyncStream<Void>.makeStream()
        let active = Task {
            try await lock.withLock {
                await recorder.record("active")
                startActive.yield()
                for await _ in activeGate {
                    break
                }
            }
        }
        for await _ in activeStarted {
            break
        }
        let queued = Task {
            try await lock.withLock { await recorder.record("stale") }
        }
        try await Task.sleep(for: .milliseconds(50))
        let wipe = Task {
            try await lock.withWalletWipe {
                try await lock.withLock { await recorder.record("cleanup") }
                startWipe.yield()
                for await _ in wipeGate {
                    break
                }
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        do {
            try await lock.withLock { await recorder.record("poll") }
            XCTFail("Expected work during wipe to be rejected")
        } catch let PaykitError.Storage(code, _) {
            XCTAssertEqual(code, "wallet_wipe_in_progress")
        }
        releaseActive.yield()
        for await _ in wipeStarted {
            break
        }
        do {
            try await queued.value
            XCTFail("Expected queued work from the old wallet to be rejected")
        } catch let PaykitError.Storage(code, _) {
            XCTAssertEqual(code, "wallet_wipe_in_progress")
        }
        releaseWipe.yield()
        try await active.value
        try await wipe.value
        try await lock.withLock { await recorder.record("fresh") }
        let events = await recorder.events
        XCTAssertEqual(events, ["active", "cleanup", "fresh"])
    }

    func testCancelledWipeDrainsActiveWorkWithoutRunningCleanup() async throws {
        let lock = PaykitSdkOperationLock()
        let (activeGate, releaseActive) = AsyncStream<Void>.makeStream()
        let (activeStarted, startActive) = AsyncStream<Void>.makeStream()
        let active = Task {
            try await lock.withLock {
                startActive.yield()
                for await _ in activeGate {
                    break
                }
            }
        }
        for await _ in activeStarted {
            break
        }
        let wipe = Task {
            try await lock.withWalletWipe { XCTFail("Cancelled wipe ran cleanup") }
        }
        try await Task.sleep(for: .milliseconds(50))
        wipe.cancel()
        releaseActive.yield()
        try await active.value
        do {
            try await wipe.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        try await lock.withLock {}
    }

    func testFailedWipeReleasesAdmission() async throws {
        let lock = PaykitSdkOperationLock()
        do {
            try await lock.withWalletWipe { throw KeychainError.failedToDelete }
            XCTFail("Expected cleanup failure")
        } catch KeychainError.failedToDelete {}
        try await lock.withLock {}
    }

    func testCancelledQueuedReadDoesNotRunAheadOfLaterWork() async throws {
        let lock = PaykitSdkOperationLock()
        let recorder = Recorder()
        let (holderGate, releaseHolder) = AsyncStream<Void>.makeStream()
        let (holderStarted, holderStartedContinuation) = AsyncStream<Void>.makeStream()

        let holder = Task {
            try await lock.withLock {
                holderStartedContinuation.yield()
                for await _ in holderGate {
                    break
                }
            }
        }
        for await _ in holderStarted {
            break
        }

        let lookup = Task {
            try await lock.withCancellableLock {
                await recorder.record("lookup")
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        let payment = Task {
            try await lock.withLock {
                await recorder.record("payment")
            }
        }
        try await Task.sleep(for: .milliseconds(50))

        lookup.cancel()
        releaseHolder.yield()
        try await holder.value
        try await payment.value

        do {
            try await lookup.value
            XCTFail("Expected the cancelled lookup to throw")
        } catch is CancellationError {}
        let events = await recorder.events
        XCTAssertEqual(events, ["payment"])
    }

    func testAlreadyCancelledReadDoesNotRunOrHoldTheLock() async throws {
        let lock = PaykitSdkOperationLock()
        let recorder = Recorder()

        let lookup = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await lock.withCancellableLock {
                await recorder.record("lookup")
            }
        }

        do {
            try await lookup.value
            XCTFail("Expected the cancelled lookup to throw")
        } catch is CancellationError {}
        try await lock.withLock {
            await recorder.record("payment")
        }
        let events = await recorder.events
        XCTAssertEqual(events, ["payment"])
    }
}
