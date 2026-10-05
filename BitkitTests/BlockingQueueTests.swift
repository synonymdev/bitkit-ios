@testable import Bitkit
import XCTest

final class BlockingQueueTests: XCTestCase {
    func testPollReturnsItemsInFifoOrder() {
        let queue = BlockingQueue<Int>()
        queue.offer(1)
        queue.offer(2)
        queue.offer(3)

        XCTAssertEqual(queue.poll(timeout: 0), 1)
        XCTAssertEqual(queue.poll(timeout: 0), 2)
        XCTAssertEqual(queue.poll(timeout: 0), 3)
    }

    func testPollTimesOutWithNil() {
        let queue = BlockingQueue<Int>()
        let start = Date()

        XCTAssertNil(queue.poll(timeout: 0.05))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.04)
    }

    func testPollWakesWhenAnItemArrives() {
        let queue = BlockingQueue<Int>()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { queue.offer(7) }

        XCTAssertEqual(queue.poll(timeout: 5), 7)
    }

    func testFailWakesABlockedPoll() {
        let queue = BlockingQueue<Int>()
        let returned = expectation(description: "blocked poll returned")
        DispatchQueue.global().async {
            XCTAssertNil(queue.poll(timeout: 10))
            returned.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.05)

        queue.fail()

        wait(for: [returned], timeout: 1)
    }

    func testClearResetsTheFailedFlag() {
        let queue = BlockingQueue<Int>()
        queue.fail()
        queue.offer(1)
        XCTAssertNil(queue.poll(timeout: 0))

        queue.clear()
        queue.offer(2)

        XCTAssertEqual(queue.poll(timeout: 0), 2)
    }

    func testDrainRemovesEverythingWithoutWaiting() {
        let queue = BlockingQueue<Int>()
        queue.offer(1)
        queue.offer(2)

        XCTAssertEqual(queue.drain(), [1, 2])
        XCTAssertEqual(queue.drain(), [])
        XCTAssertNil(queue.poll(timeout: 0))
    }
}
