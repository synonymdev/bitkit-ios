@testable import Bitkit
import XCTest

final class PaykitSdkOperationLockTests: XCTestCase {
    private actor Recorder {
        private(set) var events: [String] = []

        func record(_ event: String) {
            events.append(event)
        }
    }

    func testCancelledQueuedReadDoesNotRunAheadOfLaterWork() async throws {
        let lock = PaykitSdkOperationLock()
        let recorder = Recorder()
        let (holderGate, releaseHolder) = AsyncStream<Void>.makeStream()
        let (holderStarted, holderStartedContinuation) = AsyncStream<Void>.makeStream()

        let holder = Task {
            await lock.withLock {
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
            await lock.withLock {
                await recorder.record("payment")
            }
        }
        try await Task.sleep(for: .milliseconds(50))

        lookup.cancel()
        releaseHolder.yield()
        await holder.value
        await payment.value

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
        await lock.withLock {
            await recorder.record("payment")
        }
        let events = await recorder.events
        XCTAssertEqual(events, ["payment"])
    }
}
