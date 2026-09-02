@testable import Bitkit
import Foundation
import Paykit
import XCTest

@MainActor
final class PaykitPaymentRequestServiceTests: XCTestCase {
    func testPaymentRequestErrorsHaveUserFacingDescriptions() {
        let errors: [PaykitPaymentRequestError] = [
            .requestUnavailable,
            .requestExpired,
            .operationInProgress,
            .amountMismatch,
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription)
        }
    }

    func testContactPaymentContextClaimIsExclusiveAndIdentityBased() {
        let app = AppViewModel()
        let first = ContactPaymentContext(publicKey: "pubkycontact")
        let second = ContactPaymentContext(publicKey: "pubkycontact")

        XCTAssertTrue(app.claimContactPaymentContext(first))
        XCTAssertTrue(app.ownsContactPaymentContext(first))
        XCTAssertFalse(app.ownsContactPaymentContext(second))
        XCTAssertFalse(app.claimContactPaymentContext(second))

        app.resetSendState(preservingContactPaymentContext: true)
        XCTAssertTrue(app.ownsContactPaymentContext(first))
        app.resetSendState()
        XCTAssertFalse(app.ownsContactPaymentContext(first))
        XCTAssertTrue(app.claimContactPaymentContext(second))
    }

    func testRefreshMapsSupportedOneTimeBitcoinRequest() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let currentOnchain = PublicPaykitService.MethodId.onchainMethodId(network: Env.network, scriptType: .p2wpkh)
        let otherOnchain: PublicPaykitService.MethodId = Env.network == .bitcoin ? .testnetOnchainP2wpkh : .bitcoinOnchainP2wpkh
        let record = try paymentRequestRecord(
            amount: "0.00100000000",
            expiresAt: timestamp(now.addingTimeInterval(60)),
            endpoints: [
                PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                currentOnchain.rawValue,
                otherOnchain.rawValue,
                "btc-unsupported-method",
            ],
            metadata: #"{"order":"123"}"#
        )
        let sdk = PaymentRequestSdkMock(records: [record])
        let clock = PaymentRequestTestClock(now)
        let manager = paymentRequestManager(sdk: sdk, clock: clock)

        await manager.refresh()

        let request = try XCTUnwrap(manager.pendingRequests.first)
        XCTAssertEqual(manager.pendingRequests.count, 1)
        XCTAssertEqual(request.paymentRequestId, record.paymentRequestId)
        XCTAssertEqual(request.amountValue, "0.00100000000")
        XCTAssertEqual(request.amountSats, 100_000)
        XCTAssertEqual(
            request.acceptedPaymentEndpointIdentifiers,
            [PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue, currentOnchain.rawValue]
        )
    }

    func testIncomingParseFailuresAreReasonSpecific() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [(PaymentRequestRecord, PaykitPaymentRequest.ParseFailure)] = try [
            (paymentRequestRecord(id: "missing-role", role: nil), .missingLocalRole),
            (paymentRequestRecord(id: "outgoing", role: .payee), .outgoingRequest),
            (paymentRequestRecord(id: "unknown-role", role: .unknown), .unsupportedLocalRole),
            (paymentRequestRecord(id: "missing-terms"), .missingTerms),
            (paymentRequestRecord(id: "wrong-asset", asset: "BTC"), .unsupportedAsset),
            (paymentRequestRecord(id: "invalid-amount", amount: "not-bitcoin"), .invalidAmount),
            (paymentRequestRecord(id: "amount-out-of-range", amount: "184467440737.09551615"), .amountOutOfRange),
            (paymentRequestRecord(id: "unsupported-endpoint", endpoints: ["btc-unsupported-method"]), .noSupportedEndpoint),
            (paymentRequestRecord(id: "invalid-expiration", expiresAt: "not-a-timestamp"), .invalidExpiration),
            (paymentRequestRecord(id: "expired", expiresAt: timestamp(now)), .expired),
        ].map { record, failure in
            if record.paymentRequestId == "missing-terms" {
                var record = record
                record.terms = nil
                return (record, failure)
            }
            return (record, failure)
        }

        for (record, expectedFailure) in cases {
            guard case let .failure(failure) = PaykitPaymentRequest.parseIncoming(record: record, now: now) else {
                XCTFail("Expected \(record.paymentRequestId) to fail parsing")
                continue
            }
            XCTAssertEqual(failure, expectedFailure)
        }
    }

    func testSynchronizeLogsRedactedParseFailuresWithoutRequestData() async throws {
        let counterparty = "pubky\(String(repeating: "y", count: 52))"
        let outgoingCounterparty = "pubky\(String(repeating: "p", count: 52))"
        let unknownRoleCounterparty = "pubky\(String(repeating: "u", count: 52))"
        let secretNote = "do-not-log-this-note"
        let records = try [
            paymentRequestRecord(
                id: "do-not-log-outgoing-id",
                counterparty: outgoingCounterparty,
                role: .payee
            ),
            paymentRequestRecord(
                id: "do-not-log-unknown-role-id",
                counterparty: unknownRoleCounterparty,
                role: .unknown
            ),
            paymentRequestRecord(
                id: "do-not-log-this-id",
                counterparty: counterparty,
                asset: "BTC",
                metadata: "{\"note\":\"\(secretNote)\"}"
            ),
            paymentRequestRecord(
                id: "do-not-log-this-endpoint-id",
                counterparty: counterparty,
                endpoints: ["btc-private-unsupported-endpoint"]
            ),
            paymentRequestRecord(
                id: "do-not-log-invalid-counterparty-id",
                counterparty: "do-not-log-invalid-counterparty",
                asset: "BTC"
            ),
        ]
        let recorder = PaymentRequestLogRecorder()
        let service = PaykitPaymentRequestService(
            sdk: PaymentRequestSdkMock(records: records),
            logWarning: { recorder.append($0) }
        )

        let snapshot = try await service.synchronize()

        XCTAssertTrue(snapshot.incoming.isEmpty)
        let output = recorder.messages.joined(separator: "\n")
        XCTAssertTrue(output.contains("category=parse reason=unsupported_asset"))
        XCTAssertTrue(output.contains("category=parse reason=no_supported_endpoint"))
        XCTAssertTrue(output.contains("category=parse reason=unsupported_local_role"))
        XCTAssertTrue(output.contains("counterparty=\(PaykitPaymentRequestDiagnostics.redactedCounterparty(counterparty))"))
        XCTAssertTrue(output.contains("counterparty=\(PaykitPaymentRequestDiagnostics.redactedCounterparty(unknownRoleCounterparty))"))
        XCTAssertFalse(output.contains(PaykitPaymentRequestDiagnostics.redactedCounterparty(outgoingCounterparty)))
        XCTAssertTrue(output.contains("counterparty=<invalid>"))
        XCTAssertFalse(output.contains(counterparty))
        XCTAssertFalse(output.contains("do-not-log-this-id"))
        XCTAssertFalse(output.contains("do-not-log-this-endpoint-id"))
        XCTAssertFalse(output.contains("do-not-log-outgoing-id"))
        XCTAssertFalse(output.contains("do-not-log-unknown-role-id"))
        XCTAssertFalse(output.contains(secretNote))
        XCTAssertFalse(output.contains("btc-private-unsupported-endpoint"))
        XCTAssertFalse(output.contains("do-not-log-invalid-counterparty"))
    }

    func testRefreshDropsExpiredAndUnsupportedRequests() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: timestamp(now),
            anchor: timestamp(now),
            endsAt: nil
        )
        let records = try [
            paymentRequestRecord(id: "valid"),
            paymentRequestRecord(id: "sdk-expired", state: .proposalExpired),
            paymentRequestRecord(id: "timestamp-expired", expiresAt: timestamp(now)),
            paymentRequestRecord(id: "malformed-expiry", expiresAt: "not-a-timestamp"),
            paymentRequestRecord(id: "wrong-role", role: .payee),
            paymentRequestRecord(id: "recurring", recurrence: recurrence),
            paymentRequestRecord(id: "wrong-asset", asset: "usd"),
            paymentRequestRecord(id: "sub-satoshi", amount: "0.000000001"),
            paymentRequestRecord(id: "zero", amount: "0"),
            paymentRequestRecord(id: "unsupported-endpoint", endpoints: ["btc-unsupported-method"]),
        ]
        let sdk = PaymentRequestSdkMock(records: records)
        let clock = PaymentRequestTestClock(now)
        let manager = paymentRequestManager(sdk: sdk, clock: clock)

        await manager.refresh()

        XCTAssertEqual(manager.pendingRequests.map(\.paymentRequestId), ["valid"])
    }

    func testRefreshKeepsOneTimeBitcoinLifecycleHistory() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let records = try [
            paymentRequestRecord(id: "incoming", state: .proposed),
            paymentRequestRecord(id: "accepted", state: .accepted),
            paymentRequestRecord(id: "rejected", state: .rejected),
            paymentRequestRecord(id: "expired", state: .proposalExpired, expiresAt: timestamp(now)),
            paymentRequestRecord(id: "outgoing", state: .proposed, role: .payee),
            paymentRequestRecord(id: "recurring", state: .activeRecurring),
            paymentRequestRecord(id: "unsupported", state: .canceled, endpoints: ["btc-unsupported-method"]),
        ]
        let manager = paymentRequestManager(
            sdk: PaymentRequestSdkMock(records: records),
            clock: PaymentRequestTestClock(now)
        )

        await manager.refresh()

        XCTAssertEqual(manager.pendingRequests.map(\.paymentRequestId), ["incoming"])
        XCTAssertEqual(
            Set(manager.historyRequests.map(\.paymentRequestId)),
            Set(["incoming", "accepted", "rejected", "expired", "outgoing", "unsupported"])
        )
        XCTAssertEqual(
            manager.historyRequests.first { $0.paymentRequestId == "accepted" }?.lifecycleState,
            .accepted
        )
        XCTAssertEqual(
            manager.historyRequests.first { $0.paymentRequestId == "outgoing" }?.direction,
            .outgoing
        )
    }

    func testRefreshRejectsAmountsOutsideTheAppPaymentRange() async throws {
        let records = try [
            paymentRequestRecord(id: "one-sat", amount: "0.00000001"),
            paymentRequestRecord(id: "millisatoshi-safe-max", amount: "184467440.73709551"),
            paymentRequestRecord(id: "millisatoshi-overflow", amount: "184467440.73709552"),
            paymentRequestRecord(id: "int-max", amount: "92233720368.54775807"),
            paymentRequestRecord(id: "int-overflow", amount: "92233720368.54775808"),
            paymentRequestRecord(id: "uint64-max", amount: "184467440737.09551615"),
            paymentRequestRecord(id: "uint64-overflow", amount: "184467440737.09551616"),
        ]
        let manager = paymentRequestManager(sdk: PaymentRequestSdkMock(records: records))

        await manager.refresh()

        XCTAssertEqual(manager.pendingRequests.map(\.paymentRequestId), ["one-sat", "millisatoshi-safe-max"])
        XCTAssertEqual(manager.pendingRequests.map(\.amountSats), [1, UInt64.max / 1000])
    }

    func testPaymentAndLightningInvoiceAmountsMustMatchRequest() throws {
        let request = try XCTUnwrap(PaykitPaymentRequest(
            record: paymentRequestRecord(amount: "0.000025"),
            now: Date()
        ))

        XCTAssertTrue(request.acceptsPaymentAmount(2500))
        XCTAssertFalse(request.acceptsPaymentAmount(0))
        XCTAssertFalse(request.acceptsPaymentAmount(2501))
        XCTAssertTrue(request.acceptsLightningInvoiceAmount(milliSatoshis: nil))
        XCTAssertTrue(request.acceptsLightningInvoiceAmount(milliSatoshis: 2_500_000))
        XCTAssertFalse(request.acceptsLightningInvoiceAmount(milliSatoshis: 2_499_999))
        XCTAssertFalse(request.acceptsLightningInvoiceAmount(milliSatoshis: 2_500_001))
    }

    func testRefreshContinuesWhenPendingResponseDeliveryFails() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        await sdk.failNextProcess()
        let manager = paymentRequestManager(sdk: sdk)

        await manager.refresh()

        XCTAssertEqual(manager.pendingRequests.count, 1)
        let snapshot = await sdk.snapshot()
        XCTAssertEqual(snapshot.processCallCount, 1)
        XCTAssertEqual(snapshot.receiveCallCount, 1)
    }

    func testFailedRefreshKeepsPreviouslyLoadedRequests() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        await sdk.setRecords([])
        await sdk.setReceiveError(.receive)

        await manager.refresh()

        XCTAssertEqual(manager.pendingRequests.count, 1)
    }

    func testManagerDropsRequestWhenItExpiresWithoutAnotherRefresh() async throws {
        let expiresAt = Date().addingTimeInterval(2)
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord(expiresAt: timestamp(expiresAt))])
        let now: @Sendable () -> Date = { Date() }
        let manager = PaykitPaymentRequestManager(
            service: PaykitPaymentRequestService(sdk: sdk, now: now, logWarning: { _ in }),
            now: now,
            logWarning: { _ in }
        )
        await manager.refresh()

        XCTAssertEqual(manager.pendingRequests.count, 1)
        try await waitUntil(timeout: .seconds(5)) { manager.pendingRequests.isEmpty }
        XCTAssertEqual(manager.historyRequests.count, 1)
    }

    func testPresentedRequestRemainsPendingWithoutBeingPresentedAgain() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.requestsForPresentation().first)

        XCTAssertTrue(manager.markPresentedIfPending(request))
        await manager.refresh()

        XCTAssertEqual(manager.pendingRequests, [request])
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)
    }

    func testDeferredRequestUsesIncreasingPresentationBackoff() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = PaymentRequestTestClock(now)
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk, clock: clock)
        await manager.refresh()
        let request = try XCTUnwrap(manager.requestsForPresentation().first)

        manager.deferPresentation(request)
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)

        clock.advance(by: 2)
        XCTAssertEqual(manager.requestsForPresentation(), [request])

        manager.deferPresentation(request)
        clock.advance(by: 1)
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)

        clock.advance(by: 1)
        XCTAssertEqual(manager.requestsForPresentation(), [request])
    }

    func testAutomaticDeferredRequestFallsBackToLowFrequencyRetries() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = PaymentRequestTestClock(now)
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk, clock: clock)
        await manager.refresh()
        let request = try XCTUnwrap(manager.requestsForPresentation().first)

        for _ in 0 ..< 14 {
            XCTAssertEqual(manager.deferPresentation(request), .retryScheduled)
            XCTAssertTrue(manager.requestsForPresentation().isEmpty)
            clock.advance(by: 2)
            XCTAssertEqual(manager.requestsForPresentation(), [request])
        }

        XCTAssertEqual(manager.deferPresentation(request), .retryScheduled)
        clock.advance(by: 119)

        XCTAssertTrue(manager.requestsForPresentation().isEmpty)

        clock.advance(by: 1)

        XCTAssertEqual(manager.requestsForPresentation(), [request])
        XCTAssertEqual(manager.pendingRequests, [request])
    }

    func testRequestedDeferredRequestStopsAfterConfiguredRetries() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = PaymentRequestTestClock(now)
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk, clock: clock)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        XCTAssertTrue(manager.requestPresentation(request))

        for _ in 0 ..< 14 {
            XCTAssertEqual(manager.deferPresentation(request), .retryScheduled)
            XCTAssertTrue(manager.requestsForPresentation().isEmpty)
            clock.advance(by: 2)
            XCTAssertEqual(manager.requestsForPresentation(), [request])
        }

        XCTAssertEqual(manager.deferPresentation(request), .requestedPresentationEnded)

        XCTAssertTrue(manager.requestsForPresentation().isEmpty)
        XCTAssertNil(manager.requestedPresentationId)
        XCTAssertEqual(manager.pendingRequests, [request])
    }

    func testRequestedDeferredRequestReportsExpirationInsteadOfRetryExhaustion() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = PaymentRequestTestClock(now)
        let sdk = try PaymentRequestSdkMock(records: [
            paymentRequestRecord(expiresAt: timestamp(now.addingTimeInterval(1))),
        ])
        let manager = paymentRequestManager(sdk: sdk, clock: clock)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        XCTAssertTrue(manager.requestPresentation(request))

        clock.advance(by: 1)

        XCTAssertEqual(manager.deferPresentation(request), .requestExpired(wasRequested: true))
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)
        XCTAssertNil(manager.requestedPresentationId)
        XCTAssertTrue(manager.pendingRequests.isEmpty)
        XCTAssertEqual(manager.requestedPresentationExpirationTrigger, 0)
        XCTAssertNil(manager.consumeExpiredRequestedPresentation())
    }

    func testRequestedExpirationSurvivesSuspendedResolution() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = PaymentRequestTestClock(now)
        let sdk = try PaymentRequestSdkMock(records: [
            paymentRequestRecord(expiresAt: timestamp(now.addingTimeInterval(60))),
        ])
        let manager = paymentRequestManager(sdk: sdk, clock: clock)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        XCTAssertTrue(manager.requestPresentation(request))
        var continuation: CheckedContinuation<Void, Never>?

        let presentationTask = Task {
            await manager.presentRequests { requests in
                XCTAssertEqual(requests, [request])
                await withCheckedContinuation { continuation = $0 }
            }
        }
        try await waitUntil { continuation != nil }
        XCTAssertTrue(manager.isCurrentPresentation(request))

        clock.advance(by: 60)
        manager.reconcileExpiredRequests()

        XCTAssertFalse(manager.isCurrentPresentation(request))
        XCTAssertNil(manager.requestedPresentationId)
        XCTAssertTrue(manager.pendingRequests.isEmpty)
        XCTAssertEqual(manager.requestedPresentationExpirationTrigger, 1)
        XCTAssertEqual(manager.consumeExpiredRequestedPresentation(), request)
        XCTAssertNil(manager.consumeExpiredRequestedPresentation())

        continuation?.resume()
        _ = await presentationTask.value
    }

    func testRequestedExpirationSurvivesPresentationRetryBackoff() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = PaymentRequestTestClock(now)
        let sdk = try PaymentRequestSdkMock(records: [
            paymentRequestRecord(expiresAt: timestamp(now.addingTimeInterval(1))),
        ])
        let manager = paymentRequestManager(sdk: sdk, clock: clock)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        XCTAssertTrue(manager.requestPresentation(request))
        XCTAssertEqual(manager.deferPresentation(request), .retryScheduled)
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)

        clock.advance(by: 1)
        manager.reconcileExpiredRequests()

        XCTAssertNil(manager.requestedPresentationId)
        XCTAssertTrue(manager.pendingRequests.isEmpty)
        XCTAssertEqual(manager.requestedPresentationExpirationTrigger, 1)
        XCTAssertEqual(manager.consumeExpiredRequestedPresentation(), request)
        XCTAssertNil(manager.consumeExpiredRequestedPresentation())
    }

    func testPreparationConsumesBeforeAccepting() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        var didConsume = false

        try await manager.prepareForPayment(request) {
            let snapshot = await sdk.snapshot()
            XCTAssertTrue(snapshot.acceptedRequests.isEmpty)
            didConsume = true
        }

        XCTAssertTrue(didConsume)
        let snapshot = await sdk.snapshot()
        XCTAssertEqual(snapshot.acceptedRequests.map(\.paymentRequestId), [request.paymentRequestId])
        XCTAssertTrue(manager.pendingRequests.isEmpty)
    }

    func testPreparationFailureDefersPresentedRequest() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = PaymentRequestTestClock(now)
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk, clock: clock)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        XCTAssertTrue(manager.markPresentedIfPending(request))

        do {
            try await manager.prepareForPayment(request) {
                throw PaymentRequestSdkMockError.preparation
            }
            XCTFail("Expected payment preparation to fail")
        } catch {
            XCTAssertEqual(error as? PaymentRequestSdkMockError, .preparation)
        }

        XCTAssertEqual(manager.pendingRequests, [request])
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)
        let snapshot = await sdk.snapshot()
        XCTAssertTrue(snapshot.acceptedRequests.isEmpty)

        clock.advance(by: 2)
        XCTAssertEqual(manager.requestsForPresentation(), [request])
    }

    func testFailedAcceptanceDropsRequestRemovedFromAuthoritativeQueue() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        await sdk.failNextAcceptAfterRemoval()

        do {
            try await manager.prepareForPayment(request)
            XCTFail("Expected payment request acceptance to fail")
        } catch {
            XCTAssertEqual(error as? PaymentRequestSdkMockError, .process)
        }

        XCTAssertTrue(manager.pendingRequests.isEmpty)
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)
    }

    func testFailedRejectionDropsRequestRemovedFromAuthoritativeQueue() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        await sdk.failNextRejectAfterRemoval()

        do {
            try await manager.reject(request)
            XCTFail("Expected payment request rejection to fail")
        } catch {
            XCTAssertEqual(error as? PaymentRequestSdkMockError, .process)
        }

        XCTAssertTrue(manager.pendingRequests.isEmpty)
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)
    }

    func testPresentationOperationIsNotReentered() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        var presentationCount = 0
        var continuation: CheckedContinuation<Void, Never>?

        let presentationTask = Task {
            await manager.presentRequests { _ in
                presentationCount += 1
                await withCheckedContinuation { continuation = $0 }
            }
        }
        try await waitUntil { continuation != nil }

        await manager.presentRequests { _ in presentationCount += 1 }
        XCTAssertEqual(presentationCount, 1)

        continuation?.resume()
        _ = await presentationTask.value
        await manager.presentRequests { _ in presentationCount += 1 }
        XCTAssertEqual(presentationCount, 2)
    }

    func testClearInvalidatesInFlightPresentation() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        var wasCurrentBeforeClear = false
        var wasCurrentAfterClear = true

        await manager.presentRequests { requests in
            guard let request = requests.first else {
                XCTFail("Expected an incoming payment request")
                return
            }
            wasCurrentBeforeClear = manager.isCurrentPresentation(request)
            manager.clear()
            wasCurrentAfterClear = manager.isCurrentPresentation(request)
        }

        XCTAssertTrue(wasCurrentBeforeClear)
        XCTAssertFalse(wasCurrentAfterClear)
    }

    func testManualPresentationSupersedesInFlightAutomaticPresentation() async throws {
        let first = try paymentRequestRecord(id: "first")
        let second = try paymentRequestRecord(id: "second")
        let manager = paymentRequestManager(sdk: PaymentRequestSdkMock(records: [first, second]))
        await manager.refresh()
        let secondRequest = try XCTUnwrap(manager.pendingRequests.first { $0.paymentRequestId == "second" })
        var continuation: CheckedContinuation<Void, Never>?
        var automaticPresentationRemainedCurrent = true

        let task = Task {
            await manager.presentRequests { requests in
                guard let automaticRequest = requests.first else {
                    XCTFail("Expected an incoming payment request")
                    return
                }
                await withCheckedContinuation { continuation = $0 }
                automaticPresentationRemainedCurrent = manager.isCurrentPresentation(automaticRequest)
            }
        }
        try await waitUntil { continuation != nil }

        XCTAssertTrue(manager.requestPresentation(secondRequest))
        continuation?.resume()
        _ = await task.value

        XCTAssertFalse(automaticPresentationRemainedCurrent)
        XCTAssertEqual(manager.requestsForPresentation(), [secondRequest])
    }

    func testRequestBeingAcceptedIsExcludedFromAutomaticPresentation() async throws {
        let first = try paymentRequestRecord(id: "first")
        let second = try paymentRequestRecord(id: "second")
        let sdk = PaymentRequestSdkMock(records: [first, second])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let firstRequest = try XCTUnwrap(manager.pendingRequests.first { $0.paymentRequestId == "first" })
        await sdk.pauseNextAccept()

        let task = Task { try await manager.prepareForPayment(firstRequest) }
        try await waitUntil { await sdk.acceptIsPaused() }

        XCTAssertEqual(manager.requestsForPresentation().map(\.paymentRequestId), ["second"])

        await sdk.resumeAccept()
        try await task.value
    }

    func testAcceptedRequestStaysApprovedUntilSendFlowFinishes() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)

        try await manager.prepareForPayment(request)

        XCTAssertTrue(manager.isApprovedForPayment(request))
        manager.finishPayment(request)
        XCTAssertFalse(manager.isApprovedForPayment(request))
    }

    func testRefreshKeepsRequestVisibleWhileAcceptanceIsFinishing() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        await sdk.pauseNextProcess()

        let acceptance = Task { try await manager.prepareForPayment(request) }
        try await waitUntil { await sdk.processIsPaused() }
        await manager.refresh()

        XCTAssertEqual(manager.pendingRequests, [request])
        XCTAssertFalse(manager.isApprovedForPayment(request))

        await sdk.resumeProcess()
        try await acceptance.value
        XCTAssertTrue(manager.pendingRequests.isEmpty)
        XCTAssertTrue(manager.isApprovedForPayment(request))
    }

    func testManualPresentationRetriesWhenPrivateDetailsBecomeAvailable() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let clock = PaymentRequestTestClock(Date())
        let manager = paymentRequestManager(sdk: sdk, clock: clock)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        XCTAssertTrue(manager.markPresentedIfPending(request))
        XCTAssertTrue(manager.requestPresentation(request))

        manager.deferPresentation(request)

        XCTAssertEqual(manager.requestedPresentationId, request.id)
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)
        try await waitUntil(timeout: .seconds(4)) { manager.presentationRetryTrigger > 0 }
        clock.advance(by: 2)
        XCTAssertEqual(manager.requestsForPresentation(), [request])
    }

    func testExpiredRequestCannotBeMarkedPresented() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = PaymentRequestTestClock(now)
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord(expiresAt: timestamp(now.addingTimeInterval(60)))])
        let manager = paymentRequestManager(sdk: sdk, clock: clock)
        await manager.refresh()
        let request = try XCTUnwrap(manager.requestsForPresentation().first)
        clock.advance(by: 61)

        XCTAssertFalse(manager.markPresentedIfPending(request))
        XCTAssertTrue(manager.pendingRequests.isEmpty)
    }

    func testAcceptQueuesResponseAndRemovesRequest() async throws {
        let sharedId = "550e8400-e29b-41d4-a716-446655440000"
        let firstRecord = try paymentRequestRecord(id: sharedId)
        let secondRecord = try paymentRequestRecord(
            id: sharedId,
            counterpartyReceiverPath: PaykitReceiverPath.wallet
        )
        let thirdRecord = try paymentRequestRecord(id: sharedId, counterparty: "pubkyother")
        let fourthRecord = try paymentRequestRecord(id: "650e8400-e29b-41d4-a716-446655440000")
        let remainingIds = [secondRecord, thirdRecord, fourthRecord].map {
            PaykitPaymentRequest.ID(
                paymentRequestId: $0.paymentRequestId,
                counterparty: $0.counterparty,
                counterpartyReceiverPath: $0.counterpartyReceiverPath
            )
        }
        let sdk = PaymentRequestSdkMock(records: [firstRecord, secondRecord, thirdRecord, fourthRecord])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first(where: {
            $0.paymentRequestId == firstRecord.paymentRequestId &&
                $0.counterparty == firstRecord.counterparty &&
                $0.counterpartyReceiverPath == firstRecord.counterpartyReceiverPath
        }))

        try await manager.prepareForPayment(request)

        XCTAssertEqual(manager.pendingRequests.map(\.id), remainingIds)
        XCTAssertEqual(
            manager.historyRequests.first { $0.id == request.id }?.lifecycleState,
            .accepted
        )
        let snapshot = await sdk.snapshot()
        XCTAssertEqual(
            snapshot.acceptedRequests,
            [PaymentRequestInvocation(
                counterparty: request.counterparty,
                counterpartyReceiverPath: request.counterpartyReceiverPath,
                paymentRequestId: request.paymentRequestId
            )]
        )
    }

    func testAcceptRechecksExpirationImmediatelyBeforeAction() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = PaymentRequestTestClock(now)
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord(expiresAt: timestamp(now.addingTimeInterval(60)))])
        let manager = paymentRequestManager(sdk: sdk, clock: clock)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        clock.advance(by: 61)

        do {
            try await manager.prepareForPayment(request)
            XCTFail("Expected the expired request to be rejected locally")
        } catch {
            XCTAssertEqual(error as? PaykitPaymentRequestError, .requestExpired)
        }

        XCTAssertTrue(manager.pendingRequests.isEmpty)
        let snapshot = await sdk.snapshot()
        XCTAssertTrue(snapshot.acceptedRequests.isEmpty)
    }

    func testQueuedAcceptanceSucceedsWhenImmediateDeliveryFails() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        await sdk.failNextProcess()

        try await manager.prepareForPayment(request)

        XCTAssertTrue(manager.pendingRequests.isEmpty)
        let snapshot = await sdk.snapshot()
        XCTAssertEqual(snapshot.acceptedRequests.map(\.paymentRequestId), [request.paymentRequestId])
        XCTAssertEqual(snapshot.processCallCount, 2)
    }

    func testQueuedAcceptanceSucceedsWhenImmediateDeliveryIsCancelled() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        await sdk.cancelNextProcess()

        try await manager.prepareForPayment(request)

        XCTAssertTrue(manager.pendingRequests.isEmpty)
        let snapshot = await sdk.snapshot()
        XCTAssertEqual(snapshot.acceptedRequests.map(\.paymentRequestId), [request.paymentRequestId])
        XCTAssertEqual(snapshot.processCallCount, 2)
    }

    func testAcceptInvalidatesAnOverlappingRefreshSnapshot() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        await sdk.pauseNextPaymentRequestList()

        let refreshTask = Task { await manager.refresh() }
        try await waitUntil { await sdk.paymentRequestListIsPaused() }
        try await manager.prepareForPayment(request)
        await sdk.resumePaymentRequestList()
        await refreshTask.value

        XCTAssertTrue(manager.pendingRequests.isEmpty)
    }

    func testClearSuppressesStateChangesFromAnInFlightAccept() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        await sdk.pauseNextAccept()

        let acceptTask = Task { try await manager.prepareForPayment(request) }
        try await waitUntil { await sdk.acceptIsPaused() }
        manager.clear()
        await sdk.resumeAccept()
        try await acceptTask.value

        XCTAssertTrue(manager.pendingRequests.isEmpty)
        let snapshot = await sdk.snapshot()
        XCTAssertEqual(snapshot.receiveCallCount, 1)
    }

    func testPresentedRequestStaysQueuedWithoutAutoPresentingAfterManagerRecreation() async throws {
        let identity = "pubky\(String(repeating: "y", count: 52))"
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let store = PaymentRequestPresentationMemoryStore()
        let firstManager = PaykitPaymentRequestManager(
            service: PaykitPaymentRequestService(sdk: sdk, logWarning: { _ in }),
            presentationStore: store,
            logWarning: { _ in }
        )
        firstManager.activate(identity: identity)
        await firstManager.refresh()
        let request = try XCTUnwrap(firstManager.pendingRequests.first)
        XCTAssertTrue(firstManager.markPresentedIfPending(request))

        let restoredManager = PaykitPaymentRequestManager(
            service: PaykitPaymentRequestService(sdk: sdk, logWarning: { _ in }),
            presentationStore: store,
            logWarning: { _ in }
        )
        restoredManager.activate(identity: identity)
        await restoredManager.refresh()

        XCTAssertEqual(restoredManager.pendingRequests, [request])
        XCTAssertTrue(restoredManager.requestsForPresentation().isEmpty)
        XCTAssertTrue(restoredManager.requestPresentation(request))
        XCTAssertEqual(restoredManager.requestsForPresentation(), [request])
    }

    func testRejectRemovesOnlyMatchingRequestAndQueuesResponse() async throws {
        let firstRecord = try paymentRequestRecord(id: "first")
        let secondRecord = try paymentRequestRecord(id: "second")
        let sdk = PaymentRequestSdkMock(records: [firstRecord, secondRecord])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()

        try await manager.reject(XCTUnwrap(manager.pendingRequests.first(where: { $0.paymentRequestId == "first" })))

        XCTAssertEqual(manager.pendingRequests.map(\.paymentRequestId), ["second"])
        XCTAssertEqual(
            manager.historyRequests.first { $0.paymentRequestId == "first" }?.lifecycleState,
            .rejected
        )
        let snapshot = await sdk.snapshot()
        XCTAssertEqual(snapshot.rejectedRequests.map(\.paymentRequestId), ["first"])
        XCTAssertEqual(snapshot.processCallCount, 2)
    }

    func testEligibleTargetsRequireSavedLinkedPaymentRequestCapablePath() async {
        let savedKey = "pubky\(String(repeating: "y", count: 52))"
        let unsavedKey = "pubky\(String(repeating: "b", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [
                linkedPeer(counterparty: savedKey, path: PaykitReceiverPath.wallet, state: .linking),
                linkedPeer(counterparty: savedKey, path: PaykitReceiverPath.server, state: .linked),
                linkedPeer(counterparty: unsavedKey, path: PaykitReceiverPath.wallet, state: .linked),
            ],
            receiverPathsByPublicKey: [
                savedKey: [PaykitReceiverPath.wallet, PaykitReceiverPath.server],
                unsavedKey: [PaykitReceiverPath.wallet],
            ]
        )
        let manager = paymentRequestManager(sdk: sdk)

        await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])

        XCTAssertEqual(
            manager.eligibleTargets,
            [PaykitPaymentRequestTarget(publicKey: savedKey, receiverPath: PaykitReceiverPath.server)]
        )
    }

    func testEligibleTargetsRequireLivePaykitSession() async {
        let savedKey = "pubky\(String(repeating: "y", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: savedKey, path: PaykitReceiverPath.wallet, state: .linked)],
            receiverPathsByPublicKey: [savedKey: [PaykitReceiverPath.wallet]]
        )
        await sdk.setLiveSessionAvailable(false)
        let manager = paymentRequestManager(sdk: sdk)

        await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])

        XCTAssertTrue(manager.eligibleTargets.isEmpty)
    }

    func testEligibleTargetsRequireTheActiveIdentity() async {
        let savedKey = "pubky\(String(repeating: "y", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: savedKey, path: PaykitReceiverPath.wallet, state: .linked)],
            receiverPathsByPublicKey: [savedKey: [PaykitReceiverPath.wallet]]
        )
        await sdk.setActiveIdentity("pubky\(String(repeating: "a", count: 52))")
        let manager = paymentRequestManager(sdk: sdk)

        await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])

        XCTAssertTrue(manager.eligibleTargets.isEmpty)
    }

    func testEligibleTargetsRequirePrivatePaymentPublication() async {
        let savedKey = "pubky\(String(repeating: "y", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: savedKey, path: PaykitReceiverPath.wallet, state: .linked)],
            receiverPathsByPublicKey: [savedKey: [PaykitReceiverPath.wallet]]
        )
        let manager = paymentRequestManager(sdk: sdk, isPrivatePaymentPublishingEnabled: false)

        await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])

        XCTAssertTrue(manager.eligibleTargets.isEmpty)
    }

    func testOlderEligibilityRefreshCannotOverwriteNewerContacts() async throws {
        let firstKey = "pubky\(String(repeating: "a", count: 52))"
        let secondKey = "pubky\(String(repeating: "b", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: firstKey, path: PaykitReceiverPath.wallet, state: .linked)],
            receiverPathsByPublicKey: [firstKey: [PaykitReceiverPath.wallet]]
        )
        await sdk.pauseNextLinkedPeers()
        let manager = paymentRequestManager(sdk: sdk)

        let olderRefresh = Task {
            await manager.refreshEligibleTargets(savedPublicKeys: [firstKey])
        }
        try await waitUntil { await sdk.linkedPeersIsPaused() }
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: secondKey, path: PaykitReceiverPath.wallet, state: .linked)],
            receiverPathsByPublicKey: [secondKey: [PaykitReceiverPath.wallet]]
        )
        await manager.refreshEligibleTargets(savedPublicKeys: [secondKey])
        await sdk.resumeLinkedPeers()
        await olderRefresh.value

        XCTAssertEqual(
            manager.eligibleTargets,
            [PaykitPaymentRequestTarget(publicKey: secondKey, receiverPath: PaykitReceiverPath.wallet)]
        )
    }

    func testProposeBuildsOneTimeBitcoinTermsAndDrainsOutbox() async throws {
        let publicKey = "pubky\(String(repeating: "y", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        let expiresAt = Date(timeIntervalSince1970: 1_900_000_000)
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: publicKey, path: PaykitReceiverPath.wallet, state: .linked)],
            receiverPathsByPublicKey: [publicKey: [PaykitReceiverPath.wallet]]
        )
        try await sdk.setProposalResult(paymentRequestRecord(
            id: "outgoing",
            counterparty: publicKey,
            counterpartyReceiverPath: PaykitReceiverPath.wallet,
            role: .payee,
            expiresAt: timestamp(expiresAt)
        ))
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refreshEligibleTargets(savedPublicKeys: [publicKey])
        let target = try XCTUnwrap(manager.eligibleTargets.first)

        let request = try await manager.propose(
            PaykitPaymentRequestDraft(amountSats: 1, note: "Coffee", expiresAt: expiresAt),
            to: target
        )

        XCTAssertEqual(request.amountSats, 1)
        XCTAssertEqual(request.note, "Coffee")
        let snapshot = await sdk.snapshot()
        XCTAssertEqual(snapshot.proposedRequests.count, 1)
        XCTAssertEqual(snapshot.proposedRequests.first?.counterparty, publicKey)
        XCTAssertEqual(snapshot.proposedRequests.first?.counterpartyReceiverPath, PaykitReceiverPath.wallet)
        XCTAssertEqual(snapshot.proposedRequests.first?.amount, "0.00000001")
        XCTAssertEqual(snapshot.proposedRequests.first?.asset, "btc")
        XCTAssertNil(snapshot.proposedRequests.first?.recurrence)
        XCTAssertEqual(snapshot.proposedRequests.first?.metadata, #"{"note":"Coffee"}"#)
        XCTAssertTrue(snapshot.proposedRequests.first?.endpointIdentifiers.contains(
            PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue
        ) == true)
        XCTAssertTrue(snapshot.proposedRequests.first?.endpointIdentifiers.allSatisfy {
            PublicPaykitService.MethodId(rawValue: $0)?.onchainNetwork.map { $0 == Env.network } ?? true
        } == true)
        XCTAssertEqual(snapshot.processCallCount, 1)
    }

    func testProposeRemainsCreatedWhenImmediateDeliveryFails() async throws {
        let publicKey = "pubky\(String(repeating: "y", count: 52))"
        let expiresAt = Date(timeIntervalSince1970: 1_900_000_000)
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: publicKey, path: PaykitReceiverPath.wallet, state: .linked)],
            receiverPathsByPublicKey: [publicKey: [PaykitReceiverPath.wallet]]
        )
        try await sdk.setProposalResult(paymentRequestRecord(
            id: "outgoing",
            counterparty: publicKey,
            counterpartyReceiverPath: PaykitReceiverPath.wallet,
            role: .payee,
            expiresAt: timestamp(expiresAt)
        ))
        await sdk.failNextProcess()
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refreshEligibleTargets(savedPublicKeys: [publicKey])

        _ = try await manager.propose(
            PaykitPaymentRequestDraft(amountSats: 1, note: "", expiresAt: expiresAt),
            to: XCTUnwrap(manager.eligibleTargets.first)
        )

        XCTAssertEqual(manager.outgoingRequests.map(\.paymentRequestId), ["outgoing"])
        let snapshot = await sdk.snapshot()
        XCTAssertEqual(snapshot.proposedRequests.count, 1)
        XCTAssertEqual(snapshot.processCallCount, 1)
    }

    func testProposeRevalidatesTargetBeforeEnqueueing() async throws {
        let publicKey = "pubky\(String(repeating: "y", count: 52))"
        let expiresAt = Date(timeIntervalSince1970: 1_900_000_000)
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: publicKey, path: PaykitReceiverPath.wallet, state: .linked)],
            receiverPathsByPublicKey: [publicKey: [PaykitReceiverPath.wallet]]
        )
        try await sdk.setProposalResult(paymentRequestRecord(
            id: "outgoing",
            counterparty: publicKey,
            counterpartyReceiverPath: PaykitReceiverPath.wallet,
            role: .payee,
            expiresAt: timestamp(expiresAt)
        ))
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refreshEligibleTargets(savedPublicKeys: [publicKey])
        let target = try XCTUnwrap(manager.eligibleTargets.first)

        await sdk.configureRecipients(peers: [], receiverPathsByPublicKey: [publicKey: [PaykitReceiverPath.wallet]])

        do {
            _ = try await manager.propose(
                PaykitPaymentRequestDraft(amountSats: 1, note: "", expiresAt: expiresAt),
                to: target
            )
            XCTFail("Expected the stale target to be rejected")
        } catch let error as PaykitPaymentRequestError {
            XCTAssertEqual(error, .requestUnavailable)
        }
        let snapshot = await sdk.snapshot()
        XCTAssertTrue(snapshot.proposedRequests.isEmpty)
    }

    func testExpiredDraftIsRejectedBeforeEnqueueing() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let publicKey = "pubky\(String(repeating: "y", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: publicKey, path: PaykitReceiverPath.wallet, state: .linked)],
            receiverPathsByPublicKey: [publicKey: [PaykitReceiverPath.wallet]]
        )
        let manager = paymentRequestManager(sdk: sdk, clock: PaymentRequestTestClock(now))
        await manager.refreshEligibleTargets(savedPublicKeys: [publicKey])
        let target = try XCTUnwrap(manager.eligibleTargets.first)

        do {
            _ = try await manager.propose(
                PaykitPaymentRequestDraft(amountSats: 1, note: "", expiresAt: now),
                to: target
            )
            XCTFail("Expected the expired draft to be rejected")
        } catch let error as PaykitPaymentRequestError {
            XCTAssertEqual(error, .requestExpired)
        }
        let snapshot = await sdk.snapshot()
        XCTAssertTrue(snapshot.proposedRequests.isEmpty)
    }

    func testProposalCompletionAfterClearDoesNotRepopulateManager() async throws {
        let publicKey = "pubky\(String(repeating: "y", count: 52))"
        let expiresAt = Date(timeIntervalSince1970: 1_900_000_000)
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: publicKey, path: PaykitReceiverPath.wallet, state: .linked)],
            receiverPathsByPublicKey: [publicKey: [PaykitReceiverPath.wallet]]
        )
        try await sdk.setProposalResult(paymentRequestRecord(
            id: "outgoing",
            counterparty: publicKey,
            counterpartyReceiverPath: PaykitReceiverPath.wallet,
            role: .payee,
            expiresAt: timestamp(expiresAt)
        ))
        await sdk.pauseNextProposal()
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refreshEligibleTargets(savedPublicKeys: [publicKey])
        let target = try XCTUnwrap(manager.eligibleTargets.first)

        let task = Task {
            try await manager.propose(
                PaykitPaymentRequestDraft(amountSats: 1, note: "", expiresAt: expiresAt),
                to: target
            )
        }
        try await waitUntil { await sdk.proposalIsPaused() }
        manager.clear()
        await sdk.resumeProposal()

        let committedRequest = try await task.value
        XCTAssertEqual(committedRequest.paymentRequestId, "outgoing")
        XCTAssertTrue(manager.outgoingRequests.isEmpty)
        XCTAssertTrue(manager.eligibleTargets.isEmpty)
    }

    func testProposalDoesNotCommitAfterSdkIdentityChanges() async throws {
        let publicKey = "pubky\(String(repeating: "y", count: 52))"
        let expiresAt = Date(timeIntervalSince1970: 1_900_000_000)
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: publicKey, path: PaykitReceiverPath.wallet, state: .linked)],
            receiverPathsByPublicKey: [publicKey: [PaykitReceiverPath.wallet]]
        )
        try await sdk.setProposalResult(paymentRequestRecord(
            id: "outgoing",
            counterparty: publicKey,
            counterpartyReceiverPath: PaykitReceiverPath.wallet,
            role: .payee,
            expiresAt: timestamp(expiresAt)
        ))
        await sdk.pauseNextProposal()
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refreshEligibleTargets(savedPublicKeys: [publicKey])
        let target = try XCTUnwrap(manager.eligibleTargets.first)

        let proposal = Task {
            try await manager.propose(
                PaykitPaymentRequestDraft(amountSats: 1, note: "", expiresAt: expiresAt),
                to: target
            )
        }
        try await waitUntil { await sdk.proposalIsPaused() }
        await sdk.setActiveIdentity("pubky\(String(repeating: "a", count: 52))")
        await sdk.resumeProposal()

        do {
            _ = try await proposal.value
            XCTFail("Expected the identity change to cancel the proposal")
        } catch let error as PaykitPaymentRequestError {
            XCTAssertEqual(error, .requestUnavailable)
        }
        let snapshot = await sdk.snapshot()
        XCTAssertTrue(snapshot.proposedRequests.isEmpty)
        XCTAssertTrue(manager.outgoingRequests.isEmpty)
    }

    func testProposalReportsConfirmedDelivery() async throws {
        let publicKey = "pubky\(String(repeating: "y", count: 52))"
        let expiresAt = Date(timeIntervalSince1970: 1_900_000_000)
        let messageId: UInt64 = 7
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: publicKey, path: PaykitReceiverPath.wallet, state: .linked)],
            receiverPathsByPublicKey: [publicKey: [PaykitReceiverPath.wallet]]
        )
        try await sdk.setProposalResult(paymentRequestRecord(
            id: "outgoing",
            counterparty: publicKey,
            counterpartyReceiverPath: PaykitReceiverPath.wallet,
            role: .payee,
            expiresAt: timestamp(expiresAt),
            proposalOutboundMessageId: messageId
        ))
        await sdk.setProcessReports([
            OutboundPrivateCounterpartySendReport(
                counterparty: publicKey,
                counterpartyReceiverPath: PaykitReceiverPath.wallet,
                report: OutboundPrivateSendReport(
                    attempted: [messageId],
                    sent: [messageId],
                    failed: [],
                    reservationCleanupFailures: [],
                    recoveryMarkerFailures: []
                ),
                error: nil
            ),
        ])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refreshEligibleTargets(savedPublicKeys: [publicKey])
        let target = try XCTUnwrap(manager.eligibleTargets.first)

        let request = try await manager.propose(
            PaykitPaymentRequestDraft(amountSats: 1, note: "", expiresAt: expiresAt),
            to: target
        )

        XCTAssertEqual(request.deliveryStatus, .sent)
    }

    func testManualPresentationDoesNotFallThroughToAutomaticRequest() async throws {
        let first = try paymentRequestRecord(id: "first")
        let second = try paymentRequestRecord(id: "second")
        let manager = paymentRequestManager(sdk: PaymentRequestSdkMock(records: [first, second]))
        await manager.refresh()
        let secondRequest = try XCTUnwrap(manager.pendingRequests.first { $0.paymentRequestId == "second" })

        XCTAssertTrue(manager.requestPresentation(secondRequest))
        XCTAssertEqual(manager.requestsForPresentation(), [secondRequest])
    }

    func testSurfacedRequestsRemainScopedAcrossIdentitySwitches() async throws {
        let identityA = "pubky\(String(repeating: "a", count: 52))"
        let identityB = "pubky\(String(repeating: "b", count: 52))"
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let store = PaymentRequestPresentationMemoryStore()
        let manager = PaykitPaymentRequestManager(
            service: PaykitPaymentRequestService(sdk: sdk, logWarning: { _ in }),
            presentationStore: store,
            isAvailable: { true },
            logWarning: { _ in }
        )

        manager.activate(identity: identityA)
        await manager.refresh()
        let requestForIdentityA = try XCTUnwrap(manager.pendingRequests.first)
        XCTAssertTrue(manager.markPresentedIfPending(requestForIdentityA))

        manager.activate(identity: identityB)
        await manager.refresh()
        XCTAssertEqual(manager.requestsForPresentation().count, 1)
        let requestForIdentityB = try XCTUnwrap(manager.pendingRequests.first)
        XCTAssertTrue(manager.markPresentedIfPending(requestForIdentityB))

        manager.activate(identity: identityA)
        await manager.refresh()
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)
    }

    private func paymentRequestManager(
        sdk: PaymentRequestSdkMock,
        clock: PaymentRequestTestClock = PaymentRequestTestClock(Date()),
        isPrivatePaymentPublishingEnabled: Bool = true
    ) -> PaykitPaymentRequestManager {
        let now: @Sendable () -> Date = { clock.now() }
        let manager = PaykitPaymentRequestManager(
            service: PaykitPaymentRequestService(
                sdk: sdk,
                now: now,
                isPrivatePaymentPublishingEnabled: { isPrivatePaymentPublishingEnabled },
                logWarning: { _ in }
            ),
            presentationStore: PaymentRequestPresentationMemoryStore(),
            now: now,
            isAvailable: { true },
            logWarning: { _ in }
        )
        manager.activate(identity: "pubky\(String(repeating: "z", count: 52))")
        return manager
    }

    private func paymentRequestRecord(
        id: String = "550e8400-e29b-41d4-a716-446655440000",
        counterparty: String = "pubkypayee",
        counterpartyReceiverPath: String = PaykitReceiverPath.server,
        state: PaymentRequestLifecycleState = .proposed,
        role: PaymentRequestLocalRole? = .payer,
        amount: String = "0.001",
        asset: String = "btc",
        expiresAt: String? = nil,
        recurrence: PaymentRequestRecurrence? = nil,
        endpoints: [String] = [PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue],
        metadata: String = "{}",
        proposalOutboundMessageId: UInt64? = nil,
        proposalOutboundStatus: OutboundPrivateMessageStatus? = nil
    ) throws -> PaymentRequestRecord {
        try PaymentRequestRecord(
            counterparty: counterparty,
            counterpartyReceiverPath: counterpartyReceiverPath,
            paymentRequestId: id,
            localRole: role,
            state: state,
            proposalStreamItemId: 1,
            proposalOutboundMessageId: proposalOutboundMessageId,
            proposalOutboundStatus: proposalOutboundStatus,
            proposalEventId: "650e8400-e29b-41d4-a716-446655440000",
            terms: PaymentRequestTerms(
                amount: PaymentRequestAmount(value: amount, asset: asset),
                paymentReference: PaymentReference(text: "invoice-123"),
                proposalExpiresAt: expiresAt,
                recurrence: recurrence,
                acceptedPaymentEndpointIdentifiers: endpoints,
                metadata: PrivateJsonObject(text: metadata)
            ),
            acceptedEventId: nil,
            acceptedOutboundStatus: nil,
            rejectedEventId: nil,
            rejectedOutboundStatus: nil,
            canceledEventId: nil,
            canceledOutboundStatus: nil,
            paymentProofs: [],
            lastStreamItemId: 1,
            lastOutboundMessageId: nil,
            lastOutboundStatus: nil,
            lastEventAt: "2027-01-15T08:00:00Z",
            invalidReason: nil
        )
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func linkedPeer(counterparty: String, path: String, state: LinkedPeerState) -> LinkedPeerRecord {
        LinkedPeerRecord(
            counterparty: counterparty,
            counterpartyReceiverPath: path,
            state: state,
            lastSyncAt: nil,
            lastPrivateReceiveAt: nil,
            failureCount: 0,
            localRecoveryAttemptId: nil,
            localRecoveryMarkerCreatedAt: nil,
            localRecoveryMarkerLastError: nil,
            remoteRecoveryAttemptId: nil,
            remoteRecoveryMarkerObservedAt: nil
        )
    }
}

private final class PaymentRequestPresentationMemoryStore: PaykitPaymentRequestPresentationStoring {
    private var states: [String: Set<PaykitPaymentRequest.ID>] = [:]

    func load(identity: String) -> Set<PaykitPaymentRequest.ID> {
        states[identity] ?? []
    }

    func save(_ ids: Set<PaykitPaymentRequest.ID>, identity: String) {
        states[identity] = ids
    }
}

private final class PaymentRequestLogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var messages: [String] {
        lock.withLock { storage }
    }

    func append(_ message: String) {
        lock.withLock { storage.append(message) }
    }
}

private actor PaymentRequestSdkMock: PaykitPaymentRequestSdkHandling {
    private var activeIdentity = "pubky\(String(repeating: "z", count: 52))"
    private var records: [PaymentRequestRecord]
    private var peerRecords: [LinkedPeerRecord] = []
    private var receiverPathsByPublicKey: [String: [String]] = [:]
    private var liveSessionAvailable = true
    private var proposalResult: PaymentRequestRecord?
    private var processCallCount = 0
    private var receiveCallCount = 0
    private var processFailuresRemaining = 0
    private var processCancellationsRemaining = 0
    private var processReports: [OutboundPrivateCounterpartySendReport] = []
    private var shouldPauseNextProcess = false
    private var isProcessPaused = false
    private var processContinuation: CheckedContinuation<Void, Never>?
    private var receiveError: PaymentRequestSdkMockError?
    private var acceptedRequests: [PaymentRequestInvocation] = []
    private var rejectedRequests: [PaymentRequestInvocation] = []
    private var acceptFailuresAfterRemoval = 0
    private var rejectFailuresAfterRemoval = 0
    private var proposedRequests: [ProposedPaymentRequestInvocation] = []
    private var shouldPauseNextPaymentRequestList = false
    private var isPaymentRequestListPaused = false
    private var paymentRequestListContinuation: CheckedContinuation<Void, Never>?
    private var shouldPauseNextAccept = false
    private var isAcceptPaused = false
    private var acceptContinuation: CheckedContinuation<Void, Never>?
    private var shouldPauseNextProposal = false
    private var isProposalPaused = false
    private var proposalContinuation: CheckedContinuation<Void, Never>?
    private var shouldPauseNextLinkedPeers = false
    private var isLinkedPeersPaused = false
    private var linkedPeersContinuation: CheckedContinuation<Void, Never>?

    init(records: [PaymentRequestRecord]) {
        self.records = records
    }

    func processPendingPrivateMessages() async throws -> [OutboundPrivateCounterpartySendReport] {
        processCallCount += 1
        if shouldPauseNextProcess {
            shouldPauseNextProcess = false
            isProcessPaused = true
            await withCheckedContinuation { processContinuation = $0 }
            isProcessPaused = false
        }
        if processCancellationsRemaining > 0 {
            processCancellationsRemaining -= 1
            throw CancellationError()
        }
        guard processFailuresRemaining > 0 else { return processReports }
        processFailuresRemaining -= 1
        throw PaymentRequestSdkMockError.process
    }

    func receivePrivateMessagesFromLinkedPeers() throws -> [PrivateStreamCounterpartyIntakeReport] {
        receiveCallCount += 1
        if let receiveError {
            throw receiveError
        }
        return []
    }

    func paymentRequests() async -> [PaymentRequestRecord] {
        let snapshot = records
        guard shouldPauseNextPaymentRequestList else { return snapshot }

        shouldPauseNextPaymentRequestList = false
        isPaymentRequestListPaused = true
        await withCheckedContinuation { paymentRequestListContinuation = $0 }
        isPaymentRequestListPaused = false
        return snapshot
    }

    func identityStatus() -> IdentityStatus? {
        IdentityStatus(publicKey: activeIdentity, liveSessionAvailable: liveSessionAvailable)
    }

    func linkedPeers() async -> [LinkedPeerRecord] {
        if shouldPauseNextLinkedPeers {
            shouldPauseNextLinkedPeers = false
            isLinkedPeersPaused = true
            await withCheckedContinuation { linkedPeersContinuation = $0 }
            isLinkedPeersPaused = false
        }
        return peerRecords
    }

    func paymentRequestReceiverPaths(publicKey: String) -> [String] {
        receiverPathsByPublicKey[publicKey] ?? []
    }

    func proposePaymentRequest(
        counterparty: String,
        counterpartyReceiverPath: String,
        terms: PaymentRequestTerms,
        expectedIdentity: String
    ) async throws -> PaymentRequestRecord {
        if shouldPauseNextProposal {
            shouldPauseNextProposal = false
            isProposalPaused = true
            await withCheckedContinuation { proposalContinuation = $0 }
            isProposalPaused = false
        }
        guard PubkyPublicKeyFormat.matches(activeIdentity, expectedIdentity) else {
            throw PaykitPaymentRequestError.requestUnavailable
        }
        guard var result = proposalResult else {
            throw PaymentRequestSdkMockError.requestMissing
        }
        result.counterparty = counterparty
        result.counterpartyReceiverPath = counterpartyReceiverPath
        result.terms = terms
        records.append(result)
        proposedRequests.append(ProposedPaymentRequestInvocation(
            counterparty: counterparty,
            counterpartyReceiverPath: counterpartyReceiverPath,
            amount: terms.amount.value,
            asset: terms.amount.asset,
            expiresAt: terms.proposalExpiresAt,
            recurrence: terms.recurrence,
            endpointIdentifiers: terms.acceptedPaymentEndpointIdentifiers,
            metadata: terms.metadata.exportText()
        ))
        return result
    }

    func acceptPaymentRequest(
        counterparty: String,
        counterpartyReceiverPath: String,
        paymentRequestId: String
    ) async throws -> PaymentRequestRecord {
        if shouldPauseNextAccept {
            shouldPauseNextAccept = false
            isAcceptPaused = true
            await withCheckedContinuation { acceptContinuation = $0 }
            isAcceptPaused = false
        }

        let record = try removeRecord(
            counterparty: counterparty,
            counterpartyReceiverPath: counterpartyReceiverPath,
            id: paymentRequestId
        )
        if acceptFailuresAfterRemoval > 0 {
            acceptFailuresAfterRemoval -= 1
            throw PaymentRequestSdkMockError.process
        }
        acceptedRequests.append(PaymentRequestInvocation(
            counterparty: counterparty,
            counterpartyReceiverPath: counterpartyReceiverPath,
            paymentRequestId: paymentRequestId
        ))
        return record
    }

    func rejectPaymentRequest(
        counterparty: String,
        counterpartyReceiverPath: String,
        paymentRequestId: String,
        reason _: String?
    ) throws -> PaymentRequestRecord {
        let record = try removeRecord(
            counterparty: counterparty,
            counterpartyReceiverPath: counterpartyReceiverPath,
            id: paymentRequestId
        )
        if rejectFailuresAfterRemoval > 0 {
            rejectFailuresAfterRemoval -= 1
            throw PaymentRequestSdkMockError.process
        }
        rejectedRequests.append(PaymentRequestInvocation(
            counterparty: counterparty,
            counterpartyReceiverPath: counterpartyReceiverPath,
            paymentRequestId: paymentRequestId
        ))
        return record
    }

    func failNextProcess() {
        processFailuresRemaining += 1
    }

    func pauseNextProcess() {
        shouldPauseNextProcess = true
    }

    func processIsPaused() -> Bool {
        isProcessPaused
    }

    func resumeProcess() {
        processContinuation?.resume()
        processContinuation = nil
    }

    func cancelNextProcess() {
        processCancellationsRemaining += 1
    }

    func pauseNextPaymentRequestList() {
        shouldPauseNextPaymentRequestList = true
    }

    func paymentRequestListIsPaused() -> Bool {
        isPaymentRequestListPaused
    }

    func resumePaymentRequestList() {
        paymentRequestListContinuation?.resume()
        paymentRequestListContinuation = nil
    }

    func pauseNextAccept() {
        shouldPauseNextAccept = true
    }

    func failNextAcceptAfterRemoval() {
        acceptFailuresAfterRemoval += 1
    }

    func failNextRejectAfterRemoval() {
        rejectFailuresAfterRemoval += 1
    }

    func acceptIsPaused() -> Bool {
        isAcceptPaused
    }

    func resumeAccept() {
        acceptContinuation?.resume()
        acceptContinuation = nil
    }

    func setRecords(_ records: [PaymentRequestRecord]) {
        self.records = records
    }

    func configureRecipients(
        peers: [LinkedPeerRecord],
        receiverPathsByPublicKey: [String: [String]]
    ) {
        peerRecords = peers
        self.receiverPathsByPublicKey = receiverPathsByPublicKey
    }

    func setLiveSessionAvailable(_ value: Bool) {
        liveSessionAvailable = value
    }

    func setActiveIdentity(_ identity: String) {
        activeIdentity = identity
    }

    func setProposalResult(_ record: PaymentRequestRecord) {
        proposalResult = record
    }

    func setProcessReports(_ reports: [OutboundPrivateCounterpartySendReport]) {
        processReports = reports
    }

    func pauseNextProposal() {
        shouldPauseNextProposal = true
    }

    func proposalIsPaused() -> Bool {
        isProposalPaused
    }

    func resumeProposal() {
        proposalContinuation?.resume()
        proposalContinuation = nil
    }

    func pauseNextLinkedPeers() {
        shouldPauseNextLinkedPeers = true
    }

    func linkedPeersIsPaused() -> Bool {
        isLinkedPeersPaused
    }

    func resumeLinkedPeers() {
        linkedPeersContinuation?.resume()
        linkedPeersContinuation = nil
    }

    func setReceiveError(_ error: PaymentRequestSdkMockError?) {
        receiveError = error
    }

    func snapshot() -> PaymentRequestSdkSnapshot {
        PaymentRequestSdkSnapshot(
            processCallCount: processCallCount,
            receiveCallCount: receiveCallCount,
            acceptedRequests: acceptedRequests,
            rejectedRequests: rejectedRequests,
            proposedRequests: proposedRequests
        )
    }

    private func removeRecord(
        counterparty: String,
        counterpartyReceiverPath: String,
        id: String
    ) throws -> PaymentRequestRecord {
        guard let index = records.firstIndex(where: {
            $0.counterparty == counterparty &&
                $0.counterpartyReceiverPath == counterpartyReceiverPath &&
                $0.paymentRequestId == id
        }) else {
            throw PaymentRequestSdkMockError.requestMissing
        }
        return records.remove(at: index)
    }
}

private struct PaymentRequestSdkSnapshot {
    let processCallCount: Int
    let receiveCallCount: Int
    let acceptedRequests: [PaymentRequestInvocation]
    let rejectedRequests: [PaymentRequestInvocation]
    let proposedRequests: [ProposedPaymentRequestInvocation]
}

private struct ProposedPaymentRequestInvocation {
    let counterparty: String
    let counterpartyReceiverPath: String
    let amount: String
    let asset: String
    let expiresAt: String?
    let recurrence: PaymentRequestRecurrence?
    let endpointIdentifiers: [String]
    let metadata: String
}

private struct PaymentRequestInvocation: Equatable {
    let counterparty: String
    let counterpartyReceiverPath: String
    let paymentRequestId: String
}

private enum PaymentRequestSdkMockError: Error, Equatable {
    case preparation
    case process
    case receive
    case requestMissing
}

private final class PaymentRequestTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        date = date.addingTimeInterval(interval)
    }
}

private enum PaymentRequestTestError: Error {
    case timedOut
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @MainActor () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while await !condition() {
        guard clock.now < deadline else { throw PaymentRequestTestError.timedOut }
        try await Task.sleep(for: .milliseconds(10))
    }
}
