@testable import Bitkit
import Combine
import XCTest

/// How core's request for the pairing code a Trezor shows is answered, from core's own thread.
@MainActor
final class TrezorTransportPairingCodeTests: XCTestCase {
    // Far below the two minutes a request waits, so a request left waiting fails the test instead of stalling it
    private let transport = TrezorTransport(pairingCodeTimeout: 2)
    private var requests = 0
    private var subscription: AnyCancellable?

    override func setUp() async throws {
        try await super.setUp()
        subscription = transport.needsPairingCodePublisher.sink { [unowned self] in requests += 1 }
    }

    // Regression: a request drained the cancel a wipe sent ahead of it, so a connect that reached pairing during the
    // wipe showed the Pair Device sheet and waited for the whole pairing timeout
    func testARefusedRequestIsAnsweredAtOnceAfterACancelAndShowsNoSheet() async {
        transport.refusePairingCodeRequests()
        transport.cancelPairingCode()
        let started = ContinuousClock.now

        let code = await requestPairingCode()

        XCTAssertEqual(code, "")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        await drainMainQueue()
        XCTAssertEqual(requests, 0)
    }

    func testRequestsAreShownAgainOnceEveryRefusalIsLifted() async {
        transport.refusePairingCodeRequests()
        transport.refusePairingCodeRequests()
        transport.allowPairingCodeRequests()
        let refusedCode = await requestPairingCode()
        transport.allowPairingCodeRequests()

        let request = Task { await requestPairingCode() }
        await eventually("the pairing sheet is requested") { requests == 1 }
        transport.submitPairingCode("123456")
        let code = await request.value

        XCTAssertEqual(refusedCode, "")
        XCTAssertEqual(code, "123456")
    }

    private func requestPairingCode() async -> String {
        await Task.detached { [transport] in transport.getPairingCode() }.value
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
