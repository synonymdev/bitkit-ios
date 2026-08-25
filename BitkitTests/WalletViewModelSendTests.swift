@testable import Bitkit
import XCTest

@MainActor
final class WalletViewModelSendTests: XCTestCase {
    func testWaitForLightningPaymentTimeoutUnwindsWithoutEvent() async {
        let wallet = WalletViewModel()
        let unwound = expectation(description: "wait unwound after timeout")
        var timedOutHash: String?

        Task { @MainActor in
            do {
                _ = try await wallet.waitForLightningPayment(hash: "unwatched-hash", timeoutSeconds: 0.05) { hash in
                    timedOutHash = hash
                }
                XCTFail("Expected PaymentTimeoutError")
            } catch is Bitkit.PaymentTimeoutError {
                unwound.fulfill()
            } catch {
                XCTFail("Expected PaymentTimeoutError, got \(type(of: error)): \(error)")
            }
        }

        await fulfillment(of: [unwound], timeout: 2)
        XCTAssertEqual(timedOutHash, "unwatched-hash")
    }

    func testWaitForLightningPaymentUnwindsOnCancel() async {
        let wallet = WalletViewModel()
        let unwound = expectation(description: "wait unwound after cancel")

        let waitTask = Task { @MainActor in
            do {
                _ = try await wallet.waitForLightningPayment(hash: "unwatched-hash", timeoutSeconds: 60)
                XCTFail("Expected cancellation")
            } catch {
                unwound.fulfill()
            }
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        waitTask.cancel()
        await fulfillment(of: [unwound], timeout: 2)
    }
}
