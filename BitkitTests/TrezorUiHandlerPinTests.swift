@testable import Bitkit
import Combine
import XCTest

/// How the PIN callback core blocks on is answered: only the request still pending takes an answer, and only one sent
/// for its own id, so a late, early or stale one never carries over to the next request.
@MainActor
final class TrezorUiHandlerPinTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []
    private var publishedIds: [Int?] = []

    override func tearDown() {
        cancellables.removeAll()
        publishedIds = []
        super.tearDown()
    }

    func testASubmittedPinAnswersThePendingRequest() async {
        let handler = makeHandler()

        let pin = await requestPin(from: handler) { handler.submitPin("1234", requestId: $0) }

        XCTAssertEqual(pin, "1234")
    }

    func testCancellingEndsThePendingRequestWithAnEmptyPin() async {
        let handler = makeHandler()

        let pin = await requestPin(from: handler) { handler.cancelPin(requestId: $0) }

        XCTAssertEqual(pin, "")
    }

    func testCancellingWithoutAnIdEndsWhicheverRequestIsPending() async {
        let handler = makeHandler()

        let pin = await requestPin(from: handler) { _ in handler.cancelPin(requestId: nil) }

        XCTAssertEqual(pin, "")
    }

    func testAPinSubmittedWithNothingPendingIsDropped() async {
        let handler = makeHandler()
        handler.submitPin("stale", requestId: 1)

        let pin = await requestPin(from: handler) { handler.submitPin("1234", requestId: $0) }

        XCTAssertEqual(pin, "1234")
    }

    func testAPinSubmittedAfterItsRequestTimedOutIsDropped() async {
        let handler = makeHandler(pinTimeout: 1)
        let timedOut = await Task.detached { handler.onPinRequest() }.value
        handler.submitPin("late", requestId: 1)

        let pin = await requestPin(from: handler) { handler.submitPin("1234", requestId: $0) }

        XCTAssertEqual(timedOut, "")
        XCTAssertEqual(pin, "1234")
    }

    func testASheetLeftOpenAfterATimeoutCannotAnswerANewerRequest() async {
        let handler = makeHandler(pinTimeout: 1)
        let first = Task.detached { handler.onPinRequest() }
        await eventually("the first request is published") { publishedIds.last == 1 }
        let timedOut = await first.value
        await eventually("the timed out request is withdrawn") { publishedIds.last == .some(nil) }

        let pin = await requestPin(from: handler) { requestId in
            handler.submitPin("stale", requestId: 1)
            handler.cancelPin(requestId: 1)
            handler.submitPin("1234", requestId: requestId)
        }

        XCTAssertEqual(timedOut, "")
        XCTAssertEqual(pin, "1234")
        XCTAssertEqual(publishedIds, [nil, 1, nil, 2, nil])
    }

    func testANewRequestEndsTheOneItSupersedesAndWithdrawsItsId() async {
        let handler = makeHandler()
        let superseded = Task.detached { handler.onPinRequest() }
        await eventually("the first request is published") { publishedIds.last == 1 }

        let pin = await requestPin(from: handler) { requestId in
            handler.submitPin("stale", requestId: 1)
            handler.submitPin("1234", requestId: requestId)
        }

        let supersededPin = await superseded.value
        XCTAssertEqual(supersededPin, "")
        XCTAssertEqual(pin, "1234")
        XCTAssertEqual(publishedIds, [nil, 1, nil, 2, nil])
    }

    func testARefusedRequestIsAnsweredAtOnceAndNeverShown() async {
        let handler = makeHandler(pinTimeout: 2)

        handler.refusePinRequests()
        let refused = await Task.detached { handler.onPinRequest() }.value
        handler.allowPinRequests()
        let pin = await requestPin(from: handler) { handler.submitPin("1234", requestId: $0) }

        XCTAssertEqual(refused, "")
        XCTAssertEqual(pin, "1234")
        XCTAssertEqual(publishedIds, [nil, 1, nil])
    }

    func testRequestsAreRefusedUntilEveryRefusalIsLifted() async {
        let handler = makeHandler(pinTimeout: 2)
        handler.refusePinRequests()
        handler.refusePinRequests()

        handler.allowPinRequests()
        let refused = await Task.detached { handler.onPinRequest() }.value
        handler.allowPinRequests()
        let pin = await requestPin(from: handler) { handler.submitPin("1234", requestId: $0) }

        XCTAssertEqual(refused, "")
        XCTAssertEqual(pin, "1234")
        XCTAssertEqual(publishedIds, [nil, 1, nil])
    }

    private func makeHandler(pinTimeout: TimeInterval = 120) -> TrezorUiHandler {
        let handler = TrezorUiHandler(pinTimeout: pinTimeout)
        handler.pinRequestIds
            .sink { [weak self] in self?.publishedIds.append($0) }
            .store(in: &cancellables)
        return handler
    }

    private func requestPin(from handler: TrezorUiHandler, answer: @escaping (Int) -> Void) async -> String {
        let shownBefore = publishedIds.count
        let request = Task.detached { handler.onPinRequest() }
        await eventually("the request is published") {
            publishedIds.dropFirst(shownBefore).contains { $0 != nil }
        }
        if let requestId = publishedIds.dropFirst(shownBefore).compactMap(\.self).first {
            answer(requestId)
        }
        let pin = await request.value
        await eventually("the answered request is withdrawn") { publishedIds.last == .some(nil) }
        return pin
    }
}
