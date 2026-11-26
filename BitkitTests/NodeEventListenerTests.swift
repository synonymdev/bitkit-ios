@testable import Bitkit
import LDKNode
import XCTest

@MainActor
final class NodeEventListenerTests: XCTestCase {
    func testFailedStartsDoNotLeaveEventWaitersOrRetainNodes() async throws {
        let listener = NodeEventListener()
        for _ in 0 ..< 3 {
            var node: EventNode? = EventNode(noPointer: .init())
            let releasedNode = { [weak node] in node }
            node?.startError = TestError.failed
            do {
                try await listener.start(node: XCTUnwrap(node)) { _ in XCTFail("A failed node must not deliver events") }
                XCTFail("Expected native startup failure")
            } catch {}
            try await listener.stop(node: XCTUnwrap(node)) { _ in XCTFail("A failed node must not resume events") }
            XCTAssertEqual(node?.pollCount, 0)
            XCTAssertEqual(node?.asyncWaitCount, 0)
            node = nil
            XCTAssertNil(releasedNode())
        }
    }

    func testStartupEventIsDeliveredOnceAndEmptyQueueReleasesBeforeReplacement() async throws {
        let listener = NodeEventListener()
        for _ in 0 ..< 2 {
            var node: EventNode? = EventNode(noPointer: .init())
            let releasedNode = { [weak node] in node }
            node?.enqueue()
            let delivered = expectation(description: "Startup event delivered")
            let empty = expectation(description: "Empty queue reached")
            node?.onEmpty = { empty.fulfill() }
            try await listener.start(node: XCTUnwrap(node)) { _ in delivered.fulfill() }
            await fulfillment(of: [delivered, empty], timeout: 2)
            try await listener.stop(node: XCTUnwrap(node)) { _ in XCTFail("Unexpected resumed event") }
            XCTAssertEqual(node?.handledCount, 1)
            XCTAssertEqual(node?.asyncWaitCount, 0)
            node = nil
            XCTAssertNil(releasedNode(), "A correction cleanup failure followed by Retry must release the previous node")
        }
    }

    func testStopDrainsAcknowledgedDeliveryBeforeStoppingNode() async throws {
        let listener = NodeEventListener()
        let node = EventNode(noPointer: .init())
        node.enqueue()
        let entered = expectation(description: "Acknowledged delivery entered")
        var release: CheckedContinuation<Void, Never>?
        var delivered = false
        try await listener.start(node: node) { _ in
            await withCheckedContinuation { continuation in
                release = continuation
                entered.fulfill()
            }
            delivered = true
        }
        await fulfillment(of: [entered], timeout: 2)
        let stopping = expectation(description: "Stop requested")
        node.onStop = { XCTAssertTrue(delivered, "Native stop must follow acknowledged callback completion") }
        let stop = Task {
            stopping.fulfill()
            try await listener.stop(node: node) { _ in XCTFail("Unexpected resumption") }
        }
        await fulfillment(of: [stopping], timeout: 2)
        XCTAssertEqual(node.stopCount, 0)
        XCTAssertFalse(delivered)
        let concurrentStopRejected = expectation(description: "Concurrent stop remains rejected")
        let concurrentStop = Task {
            do {
                try await listener.stop(node: node) { _ in XCTFail("Unexpected concurrent delivery") }
                XCTFail("A concurrent stop must not replace the draining operation")
            } catch { concurrentStopRejected.fulfill() }
        }
        await fulfillment(of: [concurrentStopRejected], timeout: 2)
        release?.resume()
        try await stop.value
        await concurrentStop.value
        XCTAssertTrue(delivered)
        XCTAssertEqual(node.stopCount, 1)
        XCTAssertEqual(node.handledCount, 1)
    }

    func testAcknowledgementDoesNotBlockIndependentNodeReadsAndStopStillDrainsIt() async throws {
        let listener = NodeEventListener()
        let node = EventNode(noPointer: .init())
        node.enqueue()
        let entered = expectation(description: "Acknowledgement is held")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        node.onHandled = {
            entered.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 10), .success)
        }
        var delivered = false
        try await listener.start(node: node) { _ in delivered = true }
        await fulfillment(of: [entered], timeout: 2)
        let readFinished = expectation(description: "Independent LDK read completes while acknowledgement is held")
        let read = Task {
            let event = try await ServiceQueue.background(.ldk) { node.nextEvent() }
            XCTAssertNotNil(event)
            readFinished.fulfill()
        }
        await fulfillment(of: [readFinished], timeout: 2)
        let stopRequested = expectation(description: "Stop requested during acknowledgement")
        node.onStop = { XCTAssertTrue(delivered) }
        let stopping = Task {
            stopRequested.fulfill()
            try await listener.stop(node: node) { _ in XCTFail("Unexpected resumed delivery") }
        }
        await fulfillment(of: [stopRequested], timeout: 2)
        XCTAssertEqual(node.stopCount, 0)
        XCTAssertFalse(delivered)
        gate.signal()
        try await read.value
        try await stopping.value
        XCTAssertTrue(delivered)
        XCTAssertEqual(node.handledCount, 1)
        XCTAssertEqual(node.stopCount, 1)
    }

    func testStopFailureResumesOnlyTheRetainedNodeConsumer() async throws {
        let listener = NodeEventListener()
        let node = EventNode(noPointer: .init())
        node.stopError = TestError.failed
        let empty = expectation(description: "Initial empty queue")
        node.onEmpty = { empty.fulfill() }
        try await listener.start(node: node) { _ in XCTFail("No initial event") }
        await fulfillment(of: [empty], timeout: 2)
        let resumed = expectation(description: "Retained node resumes delivery")
        do {
            try await listener.stop(node: node) { _ in resumed.fulfill() }
            XCTFail("Expected native stop failure")
        } catch {}
        node.enqueue()
        await fulfillment(of: [resumed], timeout: 2)
        node.stopError = nil
        try await listener.stop(node: node) { _ in XCTFail("Unexpected further resumption") }
        XCTAssertEqual(node.startCount, 1)
        XCTAssertEqual(node.handledCount, 1)
    }

    func testStopDuringNativeStartDrainsStartupEvenWhenCancelled() async throws {
        for cancelStop in [false, true] {
            let listener = NodeEventListener()
            let node = EventNode(noPointer: .init())
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let entered = expectation(description: "Native startup entered")
            node.onStart = {
                entered.fulfill()
                XCTAssertEqual(gate.wait(timeout: .now() + 10), .success)
            }
            let starting = Task { try await listener.start(node: node) { _ in XCTFail("No event queued") } }
            await fulfillment(of: [entered], timeout: 2)

            let requested = expectation(description: "Stop requested during startup")
            let stopping = Task {
                requested.fulfill()
                do {
                    try await listener.stop(node: node) { _ in XCTFail("No event queued") }
                    return true
                } catch { return false }
            }
            await fulfillment(of: [requested], timeout: 2)
            if cancelStop {
                stopping.cancel()
            }
            XCTAssertEqual(node.stopCount, 0)
            gate.signal()
            try await starting.value
            let stopped = await stopping.value
            XCTAssertTrue(stopped, "Stop must drain the original start, including cancellation")
            XCTAssertEqual(node.startCount, 1)
            XCTAssertEqual(node.stopCount, 1)
            if !stopped {
                try await listener.stop(node: node) { _ in XCTFail("Unexpected cleanup event") }
            }
        }
    }

    func testStopWaitingForFailedStartCompletesWithoutAnEventConsumer() async {
        let listener = NodeEventListener()
        let node = EventNode(noPointer: .init())
        node.startError = TestError.failed
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let entered = expectation(description: "Failing startup entered")
        node.onStart = {
            entered.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 10), .success)
        }
        let starting = Task {
            do {
                try await listener.start(node: node) { _ in XCTFail("Failed startup cannot deliver events") }
                XCTFail("Expected startup failure")
            } catch {}
        }
        await fulfillment(of: [entered], timeout: 2)
        let requested = expectation(description: "Stop requested before startup failure")
        let stopping = Task {
            requested.fulfill()
            do {
                try await listener.stop(node: node) { _ in XCTFail("Failed startup cannot resume events") }
                return true
            } catch { return false }
        }
        await fulfillment(of: [requested], timeout: 2)
        gate.signal()
        await starting.value
        let stopped = await stopping.value
        XCTAssertTrue(stopped, "An unsuccessful start must release its waiting stop")
        XCTAssertEqual(node.startCount, 0)
        XCTAssertEqual(node.pollCount, 0)
    }

    func testStopAlreadyWaitingForStartupRejectsAnotherStop() async throws {
        let listener = NodeEventListener()
        let node = EventNode(noPointer: .init())
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let entered = expectation(description: "Startup held before completion")
        node.onStart = {
            entered.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 10), .success)
        }
        let starting = Task { try await listener.start(node: node) { _ in XCTFail("No event queued") } }
        await fulfillment(of: [entered], timeout: 2)
        let requested = expectation(description: "First stop owns pending cleanup")
        let firstStop = Task {
            requested.fulfill()
            do {
                try await listener.stop(node: node) { _ in XCTFail("No event queued") }
                return true
            } catch { return false }
        }
        await fulfillment(of: [requested], timeout: 2)
        let rejected = expectation(description: "Second stop rejected before startup completes")
        let secondStop = Task {
            do {
                try await listener.stop(node: node) { _ in XCTFail("Unexpected replacement delivery") }
                XCTFail("The first waiting stop must retain lifecycle ownership")
            } catch { rejected.fulfill() }
        }
        await fulfillment(of: [rejected], timeout: 2)
        gate.signal()
        try await starting.value
        let firstStopped = await firstStop.value
        await secondStop.value
        XCTAssertTrue(firstStopped)
        XCTAssertEqual(node.stopCount, 1)
    }
}

private enum TestError: Error { case failed }

private final class EventNode: Node {
    var startError: Error?
    var stopError: Error?
    var onStart: (() -> Void)?
    var onEmpty: (() -> Void)?
    var onStop: (() -> Void)?
    var onHandled: (() -> Void)?
    private let lock = NSLock()
    private var running = false
    private var event: Event?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var pollCount = 0
    private(set) var handledCount = 0
    private(set) var asyncWaitCount = 0

    func enqueue() {
        lock.withLock { event = .syncCompleted(syncType: .onchainWallet, syncedBlockHeight: 1) }
    }

    override func start() throws {
        onStart?()
        if let startError {
            throw startError
        }
        running = true
        startCount += 1
    }

    override func stop() throws {
        if let stopError {
            throw stopError
        }
        guard running else { throw NodeError.NotRunning(message: "not running") }
        onStop?()
        running = false
        stopCount += 1
    }

    override func nextEvent() -> Event? {
        lock.withLock {
            pollCount += 1
            if event == nil {
                onEmpty?()
                onEmpty = nil
            }
            return event
        }
    }

    override func nextEventAsync() async -> Event {
        asyncWaitCount += 1
        XCTFail("The native asynchronous wait cannot be cancelled")
        return .syncCompleted(syncType: .onchainWallet, syncedBlockHeight: 1)
    }

    override func eventHandled() throws {
        onHandled?()
        lock.withLock {
            handledCount += 1
            event = nil
        }
    }
}
