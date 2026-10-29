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
        release?.resume()
        try await stop.value
        XCTAssertTrue(delivered)
        XCTAssertEqual(node.stopCount, 1)
        XCTAssertEqual(node.handledCount, 1)
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
}

private enum TestError: Error { case failed }

private final class EventNode: Node {
    var startError: Error?
    var stopError: Error?
    var onEmpty: (() -> Void)?
    var onStop: (() -> Void)?
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
        lock.withLock {
            handledCount += 1
            event = nil
        }
    }
}
