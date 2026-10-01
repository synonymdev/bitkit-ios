@testable import Bitkit
import XCTest

final class PaykitSdkReadLimiterTests: XCTestCase {
    private actor Recorder {
        private(set) var events: [String] = []

        func record(_ event: String) {
            events.append(event)
        }
    }

    private struct ReadFailure: Error {}

    private typealias SlotRun = @Sendable (@Sendable () async -> Void) async throws -> Void

    private struct Gate {
        private let signal = AsyncStream<Void>.makeStream()

        func wait() async {
            for await _ in signal.stream {}
        }

        func open() {
            signal.continuation.finish()
        }
    }

    /// Starts a read that records `name` once it holds a slot, then keeps the slot until `gate` opens.
    private func startGatedRead(
        _ name: String,
        on limiter: PaykitSdkReadLimiter,
        recorder: Recorder,
        gate: Gate
    ) -> Task<Void, Error> {
        Task {
            try await limiter.withSlot {
                await recorder.record(name)
                await gate.wait()
            }
        }
    }

    private func startGatedRead(
        _ name: String,
        on slots: PaykitPublicReadSlots,
        priority: PaykitPublicReadPriority,
        recorder: Recorder,
        gate: Gate
    ) -> Task<Void, Error> {
        Task {
            try await slots.withSlot(priority) {
                await recorder.record(name)
                await gate.wait()
            }
        }
    }

    private func waitForEvents(_ recorder: Recorder, count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await recorder.events.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testConcurrentReadsNeverExceedTheCap() async throws {
        let limiter = PaykitSdkReadLimiter(maxConcurrent: 2)
        let recorder = Recorder()
        let gates = [Gate(), Gate(), Gate()]

        let first = startGatedRead("first", on: limiter, recorder: recorder, gate: gates[0])
        let second = startGatedRead("second", on: limiter, recorder: recorder, gate: gates[1])
        try await waitForEvents(recorder, count: 2)
        let third = startGatedRead("third", on: limiter, recorder: recorder, gate: gates[2])
        try await Task.sleep(for: .milliseconds(50))

        let eventsAtCap = await recorder.events
        XCTAssertEqual(Set(eventsAtCap), ["first", "second"])

        gates[0].open()
        try await first.value
        try await waitForEvents(recorder, count: 3)
        let eventsAfterRelease = await recorder.events
        XCTAssertEqual(eventsAfterRelease.last, "third")

        gates[1].open()
        gates[2].open()
        try await second.value
        try await third.value
    }

    func testQueuedReadsRunInArrivalOrder() async throws {
        let limiter = PaykitSdkReadLimiter(maxConcurrent: 1)
        let recorder = Recorder()
        let holderGate = Gate()
        let holder = startGatedRead("holder", on: limiter, recorder: recorder, gate: holderGate)
        try await waitForEvents(recorder, count: 1)

        var queued: [Task<Void, Error>] = []
        for name in ["a", "b", "c"] {
            queued.append(Task {
                try await limiter.withSlot {
                    await recorder.record(name)
                }
            })
            try await Task.sleep(for: .milliseconds(50))
        }

        holderGate.open()
        try await holder.value
        for task in queued {
            try await task.value
        }
        let events = await recorder.events
        XCTAssertEqual(events, ["holder", "a", "b", "c"])
    }

    /// A cancelled read throws while the slot it queues for is still held and takes no slot, so the read queued behind it
    /// runs next. A bulk read holding its bulk slot while it waits for a read slot gives that bulk slot up.
    func testCancelledQueuedReadLeavesQueueWithoutTakingASlot() async throws {
        let limiter = PaykitSdkReadLimiter(maxConcurrent: 1)
        let slots = PaykitPublicReadSlots(readCap: 1, bulkCap: 1)
        let cases: [(name: String, hold: SlotRun, queue: SlotRun)] = [
            ("queued read", { try await limiter.withSlot($0) }, { try await limiter.withSlot($0) }),
            ("bulk read waiting for a read slot", { try await slots.withSlot(.interactive, $0) }, { try await slots.withSlot(.bulk, $0) }),
        ]
        for testCase in cases {
            let recorder = Recorder()
            let holderGate = Gate()
            let holder = Task {
                try await testCase.hold {
                    await recorder.record("holder")
                    await holderGate.wait()
                }
            }
            try await waitForEvents(recorder, count: 1)

            let abandonedThrew = expectation(description: "\(testCase.name): cancelled read threw while the slot was still held")
            let abandoned = Task {
                do {
                    try await testCase.queue { await recorder.record("abandoned") }
                } catch is CancellationError {
                    abandonedThrew.fulfill()
                }
            }
            try await Task.sleep(for: .milliseconds(50))
            let next = Task { try await testCase.queue { await recorder.record("next") } }
            try await Task.sleep(for: .milliseconds(50))

            abandoned.cancel()
            await fulfillment(of: [abandonedThrew], timeout: 2)

            holderGate.open()
            for read in [abandoned, holder, next] {
                let result = await read.result
                XCTAssertNoThrow(try result.get(), testCase.name)
            }
            do {
                try await testCase.queue { await recorder.record("after") }
            } catch {
                XCTFail("\(testCase.name): \(error)")
            }
            let events = await recorder.events
            XCTAssertEqual(events, ["holder", "next", "after"], testCase.name)
        }
    }

    func testAlreadyCancelledReadDoesNotRunOrTakeASlot() async throws {
        let limiter = PaykitSdkReadLimiter(maxConcurrent: 1)
        let recorder = Recorder()

        let lookup = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await limiter.withSlot {
                await recorder.record("lookup")
            }
        }

        do {
            try await lookup.value
            XCTFail("Expected the cancelled lookup to throw")
        } catch is CancellationError {}
        try await limiter.withSlot {
            await recorder.record("payment")
        }
        let events = await recorder.events
        XCTAssertEqual(events, ["payment"])
    }

    func testBulkReadsLeaveReadSlotsFreeForInteractiveReads() async throws {
        let slots = PaykitPublicReadSlots()
        let recorder = Recorder()
        var gates: [String: Gate] = [:]
        var reads: [Task<Void, Error>] = []
        func start(_ name: String, _ priority: PaykitPublicReadPriority) {
            let gate = Gate()
            gates[name] = gate
            reads.append(startGatedRead(name, on: slots, priority: priority, recorder: recorder, gate: gate))
        }

        for index in 0 ..< 4 {
            start("bulk\(index)", .bulk)
            try await waitForEvents(recorder, count: index + 1)
        }
        start("bulk4", .bulk)
        try await Task.sleep(for: .milliseconds(50))
        let bulkEvents = await recorder.events
        XCTAssertEqual(bulkEvents, ["bulk0", "bulk1", "bulk2", "bulk3"], "Only four bulk reads may run at once")

        start("interactive0", .interactive)
        start("interactive1", .interactive)
        try await waitForEvents(recorder, count: 6)
        let eventsWithInteractive = await recorder.events
        XCTAssertEqual(Set(eventsWithInteractive.suffix(2)), ["interactive0", "interactive1"])

        start("interactive2", .interactive)
        try await Task.sleep(for: .milliseconds(50))
        let eventsAtReadCap = await recorder.events
        XCTAssertEqual(eventsAtReadCap.count, 6, "No more than six reads may run at once")

        gates["bulk0"]?.open()
        try await waitForEvents(recorder, count: 7)
        try await Task.sleep(for: .milliseconds(50))
        let eventsAfterBulkRelease = await recorder.events
        XCTAssertEqual(eventsAfterBulkRelease.count, 7)
        XCTAssertEqual(eventsAfterBulkRelease.last, "interactive2", "A freed read slot goes to the queued interactive read")

        gates.values.forEach { $0.open() }
        for read in reads {
            try await read.value
        }
        let finalEvents = await recorder.events
        XCTAssertEqual(finalEvents.last, "bulk4")
    }

    func testFailingReadReleasesItsSlotToTheNextWaiter() async throws {
        let limiter = PaykitSdkReadLimiter(maxConcurrent: 1)
        let recorder = Recorder()
        let holderGate = Gate()
        let failing = Task {
            try await limiter.withSlot {
                await recorder.record("failing")
                await holderGate.wait()
                throw ReadFailure()
            }
        }
        try await waitForEvents(recorder, count: 1)
        let next = Task {
            try await limiter.withSlot {
                await recorder.record("next")
            }
        }
        try await Task.sleep(for: .milliseconds(50))

        holderGate.open()
        do {
            try await failing.value
            XCTFail("Expected the failing read to throw")
        } catch is ReadFailure {}
        try await next.value
        try await limiter.withSlot {
            await recorder.record("after")
        }
        let events = await recorder.events
        XCTAssertEqual(events, ["failing", "next", "after"])
    }
}
