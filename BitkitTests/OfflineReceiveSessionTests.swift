@testable import Bitkit
import XCTest

@MainActor
final class OfflineReceiveSessionTests: XCTestCase {
    func testLiveProviderDoesNotAdvertiseOfflineSupport() async throws {
        let session = OfflineReceiveSession(provider: UnavailableOfflineReceiveProvider())
        await session.updateEligibility(eligibility())
        session.setSelected(true)

        XCTAssertFalse(session.isEligible)
        XCTAssertFalse(session.isSelected)
        do {
            _ = try await session.prepareInvoice(eligibility: eligibility(), description: "")
            XCTFail("Unsupported offline receiving must fail")
        } catch {
            XCTAssertTrue(error is OfflineReceiveError)
        }
    }

    func testInvalidAmountsAndWalletStatesDoNotQueryProvider() async {
        let provider = TestOfflineReceiveProvider()
        let session = OfflineReceiveSession(provider: provider)
        for request in [
            eligibility(amount: 0),
            eligibility(amount: 1001),
            eligibility(capacity: nil),
            eligibility(capacity: 0),
            eligibility(isNodeRunning: false),
            eligibility(supportsLightning: false),
        ] {
            await session.updateEligibility(request)
            session.setSelected(true)
            XCTAssertFalse(session.isEligible)
            XCTAssertFalse(session.isSelected)
        }
        XCTAssertTrue(provider.queriedAmounts.isEmpty)
    }

    func testExactLiquidityBoundaryRequiresProviderSupport() async {
        let provider = TestOfflineReceiveProvider()
        provider.supported = false
        let session = OfflineReceiveSession(provider: provider)
        await session.updateEligibility(eligibility())
        XCTAssertFalse(session.isEligible)

        provider.supported = true
        await session.updateEligibility(eligibility())
        session.setSelected(true)
        XCTAssertTrue(session.canSelect(for: eligibility()))
        XCTAssertTrue(session.isSelected)
        XCTAssertEqual(provider.queriedAmounts, [1000, 1000])
    }

    func testEditingAmountClearsSelectionAndOldEligibility() async {
        let provider = TestOfflineReceiveProvider()
        let session = OfflineReceiveSession(provider: provider)
        await session.updateEligibility(eligibility())
        session.setSelected(true)

        XCTAssertFalse(session.canSelect(for: eligibility(amount: 999)))
        await session.updateEligibility(eligibility(amount: 999))
        XCTAssertTrue(session.isEligible)
        XCTAssertFalse(session.isSelected)
        XCTAssertEqual(provider.queriedAmounts, [1000, 999])
    }

    func testLiquidityLossClearsSelection() async {
        let session = OfflineReceiveSession(provider: TestOfflineReceiveProvider())
        await session.updateEligibility(eligibility())
        session.setSelected(true)
        await session.updateEligibility(eligibility(capacity: 999))

        XCTAssertFalse(session.isEligible)
        XCTAssertFalse(session.isSelected)
    }

    func testProviderFailureClearsSelection() async {
        let provider = TestOfflineReceiveProvider()
        let session = OfflineReceiveSession(provider: provider)
        await session.updateEligibility(eligibility())
        session.setSelected(true)
        provider.query = { _ in throw TestFailure.activationFailed }

        await session.updateEligibility(eligibility())

        XCTAssertFalse(session.isEligible)
        XCTAssertFalse(session.isSelected)
    }

    func testResetClearsSelectedInvoice() async {
        let session = OfflineReceiveSession(provider: TestOfflineReceiveProvider())
        await session.updateEligibility(eligibility())
        session.setSelected(true)

        session.reset()

        XCTAssertFalse(session.isEligible)
        XCTAssertFalse(session.isSelected)
    }

    func testStaleEligibilityCannotRestoreSelection() async {
        let provider = TestOfflineReceiveProvider()
        let started = expectation(description: "Provider query started")
        var reply: CheckedContinuation<Bool, Error>?
        provider.query = { _ in
            try await withCheckedThrowingContinuation { continuation in
                reply = continuation
                started.fulfill()
            }
        }
        let session = OfflineReceiveSession(provider: provider)
        let task = Task { await session.updateEligibility(eligibility()) }
        await fulfillment(of: [started], timeout: 1)
        await session.updateEligibility(eligibility(amount: 0))
        reply?.resume(returning: true)
        await task.value

        XCTAssertFalse(session.isEligible)
        XCTAssertFalse(session.isSelected)
    }

    func testNewSessionInvalidatesPendingEligibility() async {
        let provider = TestOfflineReceiveProvider()
        let started = expectation(description: "Provider query started")
        var reply: CheckedContinuation<Bool, Error>?
        provider.query = { _ in
            try await withCheckedThrowingContinuation { continuation in
                reply = continuation
                started.fulfill()
            }
        }
        let session = OfflineReceiveSession(provider: provider)
        let task = Task { await session.updateEligibility(eligibility()) }
        await fulfillment(of: [started], timeout: 1)
        session.reset()
        reply?.resume(returning: true)
        await task.value

        XCTAssertFalse(session.isEligible)
        XCTAssertFalse(session.isSelected)
    }

    func testPreparationRechecksSupportAndDoesNotCreateWhenItWasRevoked() async {
        let provider = TestOfflineReceiveProvider()
        let session = OfflineReceiveSession(provider: provider)
        await session.updateEligibility(eligibility())
        provider.supported = false

        do {
            _ = try await session.prepareInvoice(eligibility: eligibility(), description: "Test")
            XCTFail("Revoked support must not create an invoice")
        } catch {
            XCTAssertTrue(error is OfflineReceiveError)
        }
        XCTAssertEqual(provider.queriedAmounts, [1000, 1000])
        XCTAssertEqual(provider.prepareCount, 0)
    }

    func testPreparationFailureIsPropagatedWithoutAnotherInvoiceAttempt() async {
        let provider = TestOfflineReceiveProvider()
        provider.preparationError = TestFailure.activationFailed
        let session = OfflineReceiveSession(provider: provider)

        do {
            _ = try await session.prepareInvoice(eligibility: eligibility(), description: "Test")
            XCTFail("Failed activation must not return an invoice")
        } catch {
            XCTAssertEqual(error as? TestFailure, .activationFailed)
        }
        XCTAssertEqual(provider.prepareCount, 1)
    }

    func testPreparationPassesExactAmountAndDescription() async throws {
        let provider = TestOfflineReceiveProvider()
        let session = OfflineReceiveSession(provider: provider)
        let result = try await session.prepareInvoice(eligibility: eligibility(), description: "Test")

        XCTAssertEqual(result.bolt11, "prepared-offline-invoice")
        XCTAssertEqual(provider.preparedAmount, 1000)
        XCTAssertEqual(provider.preparedDescription, "Test")
    }

    func testRetryKeepsRequestIdentityAfterAReservationConsumesLiquidity() async throws {
        let provider = TestOfflineReceiveProvider()
        provider.preparationError = TestFailure.activationFailed
        let session = OfflineReceiveSession(provider: provider)
        await session.updateEligibility(eligibility())
        session.setSelected(true)
        do {
            _ = try await session.prepareInvoice(eligibility: eligibility(), description: "Test")
            XCTFail("Expected lost activation response")
        } catch {}

        provider.supported = false
        provider.preparationError = nil
        await session.updateEligibility(eligibility(capacity: 0))
        XCTAssertTrue(session.isSelected)
        _ = try await session.prepareInvoice(eligibility: eligibility(capacity: 0), description: "Test")

        XCTAssertEqual(provider.requestIds.count, 2)
        XCTAssertEqual(provider.requestIds.first, provider.requestIds.last)
        XCTAssertEqual(provider.queriedAmounts, [1000, 1000])

        await session.updateEligibility(eligibility(supportsLightning: false))
        XCTAssertFalse(session.isSelected)
    }

    func testEditedRequestAndNewSessionUseNewIdentities() async throws {
        let provider = TestOfflineReceiveProvider()
        let session = OfflineReceiveSession(provider: provider)
        _ = try await session.prepareInvoice(eligibility: eligibility(), description: "First")
        _ = try await session.prepareInvoice(eligibility: eligibility(), description: "Second")
        _ = try await session.prepareInvoice(eligibility: eligibility(amount: 999), description: "Second")
        session.reset()
        _ = try await session.prepareInvoice(eligibility: eligibility(amount: 999), description: "Second")

        XCTAssertEqual(Set(provider.requestIds).count, 4)
    }

    func testPreparedInvoiceCanBeDisplayedWithoutNodeOrNetworkUntilExpiry() {
        let now = Date(timeIntervalSince1970: 1000)
        let invoice = OfflineReceiveInvoice(
            bolt11: "prepared-offline-invoice",
            amountSats: 1000,
            note: "Test",
            paymentHash: "payment-hash",
            expiresAt: now.addingTimeInterval(60)
        )

        XCTAssertTrue(invoice.canDisplay(amountSats: 1000, note: "Test", now: now))
        XCTAssertFalse(invoice.canDisplay(amountSats: 1000, note: "Test", now: now.addingTimeInterval(60)))
        XCTAssertFalse(invoice.canDisplay(amountSats: 999, note: "Test", now: now))
        XCTAssertFalse(invoice.canDisplay(amountSats: 1000, note: "Edited", now: now))
    }

    private func eligibility(
        amount: UInt64 = 1000,
        capacity: UInt64? = 1000,
        isNodeRunning: Bool = true,
        supportsLightning: Bool = true
    ) -> OfflineReceiveEligibility {
        OfflineReceiveEligibility(
            amountSats: amount,
            inboundCapacitySats: capacity,
            isNodeRunning: isNodeRunning,
            supportsLightning: supportsLightning
        )
    }
}

private enum TestFailure: Error {
    case activationFailed
}

@MainActor
private final class TestOfflineReceiveProvider: OfflineReceiveProviding {
    var supported = true
    var queriedAmounts: [UInt64] = []
    var prepareCount = 0
    var preparedAmount: UInt64?
    var preparedDescription: String?
    var preparationError: Error?
    var requestIds: [String] = []
    var query: ((UInt64) async throws -> Bool)?

    func canReceive(amountSats: UInt64) async throws -> Bool {
        queriedAmounts.append(amountSats)
        if let query { return try await query(amountSats) }
        return supported
    }

    func prepareInvoice(requestId: String, amountSats: UInt64, description: String) async throws -> PreparedOfflineInvoice {
        prepareCount += 1
        requestIds.append(requestId)
        if let preparationError { throw preparationError }
        preparedAmount = amountSats
        preparedDescription = description
        return PreparedOfflineInvoice(bolt11: "prepared-offline-invoice")
    }
}
