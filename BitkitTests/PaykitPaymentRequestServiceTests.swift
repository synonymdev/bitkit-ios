@testable import Bitkit
import Foundation
import Paykit
import UserNotifications
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

    func testSubscriptionNotificationTargetRoundTripsExactBillingPeriod() throws {
        defer { PaykitSubscriptionNotificationTargetStore.clear() }
        PaykitSubscriptionNotificationTargetStore.clear()
        let counterparty = "pubky\(String(repeating: "y", count: 52))"
        let payerIdentity = "pubky\(String(repeating: "z", count: 52))"
        let userInfo: [AnyHashable: Any] = [
            "payer_identity": payerIdentity,
            "payment_request_id": "subscription-id",
            "counterparty": counterparty,
            "counterparty_receiver_path": "bitkit/server",
            "billing_period_starts_at": "2026-08-25T12:00:00Z",
        ]

        let target = try XCTUnwrap(PaykitSubscriptionNotificationTarget(userInfo: userInfo))
        PaykitSubscriptionNotificationTargetStore.save(target)

        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "week",
            startsAt: "2026-08-25T12:00:00Z",
            anchor: "2026-08-25T12:00:00Z",
            endsAt: nil
        )
        let record = try paymentRequestRecord(
            id: "subscription-id",
            counterparty: counterparty,
            state: .activeRecurring,
            recurrence: recurrence
        )
        let subscription = try XCTUnwrap(PaykitSubscription(record: record))
        let acceptedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-24T12:00:00Z"))
        let through = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-26T12:00:00Z"))
        let request = try XCTUnwrap(subscription.requests(through: through, acceptedAt: acceptedAt).first)

        XCTAssertEqual(PaykitSubscriptionNotificationTargetStore.load(), target)
        XCTAssertTrue(target.matches(identity: payerIdentity))
        XCTAssertTrue(target.matches(request))
        PaykitSubscriptionNotificationTargetStore.clear()
        XCTAssertNil(PaykitSubscriptionNotificationTargetStore.load())
    }

    func testSubscriptionNotificationIdentifiersAreScopedToPayerIdentity() throws {
        let startsAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-01T08:00:00Z"))
        let requestId = PaykitPaymentRequest.ID(
            paymentRequestId: "subscription",
            counterparty: "pubkypayee",
            counterpartyReceiverPath: PaykitReceiverPath.server,
            billingPeriodStartsAt: startsAt
        )

        XCTAssertNotEqual(
            PaykitSubscriptionNotificationIdentifier.identifier(identity: "pubkypayer-a", requestId: requestId),
            PaykitSubscriptionNotificationIdentifier.identifier(identity: "pubkypayer-b", requestId: requestId)
        )
    }

    func testSubscriptionAcceptanceHistoryDistinguishesRejectedProposalFromCanceledSubscription() throws {
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let rejectedProposal = try XCTUnwrap(PaykitSubscription(record: paymentRequestRecord(
            state: .rejected,
            recurrence: recurrence
        )))
        let canceledSubscription = try XCTUnwrap(PaykitSubscription(record: paymentRequestRecord(
            state: .canceled,
            recurrence: recurrence,
            acceptedEventId: "accepted-event"
        )))

        XCTAssertFalse(rejectedProposal.wasAccepted)
        XCTAssertTrue(canceledSubscription.wasAccepted)
    }

    func testCanceledSubscriptionDoesNotRetainNotificationFromStaleSynchronization() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "week",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let subscription = try XCTUnwrap(PaykitSubscription(record: paymentRequestRecord(
            state: .activeRecurring,
            recurrence: recurrence
        )))
        let center = PaykitSubscriptionNotificationCenterMock()
        let scheduler = PaykitSubscriptionNotificationScheduler(center: center)
        await center.pauseNextAdd()

        let synchronization = Task {
            await scheduler.synchronize(
                [subscription],
                acceptedAt: [subscription.id: now],
                pendingRequestIds: [],
                payerIdentity: "pubky\(String(repeating: "z", count: 52))",
                notificationsEnabled: true,
                now: now
            )
        }
        try await waitUntil { await center.isAddPaused }
        await scheduler.cancel()
        await center.resumeAdd()
        await synchronization.value

        let pendingIdentifiers = await center.pendingIdentifiers
        XCTAssertTrue(pendingIdentifiers.isEmpty)
    }

    func testDisablingNotificationsRemovesPendingSubscriptionPeriodNotification() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "week",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let subscription = try XCTUnwrap(PaykitSubscription(record: paymentRequestRecord(
            state: .activeRecurring,
            recurrence: recurrence
        )))
        let request = try XCTUnwrap(subscription.paymentDueOnAcceptance(at: now))
        let payerIdentity = "pubky\(String(repeating: "z", count: 52))"
        let identifier = try XCTUnwrap(
            PaykitSubscriptionNotificationIdentifier.identifier(identity: payerIdentity, requestId: request.id)
        )
        let center = PaykitSubscriptionNotificationCenterMock()
        try await center.add(UNNotificationRequest(
            identifier: identifier,
            content: UNMutableNotificationContent(),
            trigger: nil
        ))
        let scheduler = PaykitSubscriptionNotificationScheduler(center: center)

        await scheduler.synchronize(
            [subscription],
            acceptedAt: [subscription.id: now],
            pendingRequestIds: [request.id],
            payerIdentity: payerIdentity,
            notificationsEnabled: false,
            now: now
        )

        let pendingIdentifiers = await center.pendingIdentifiers
        XCTAssertTrue(pendingIdentifiers.isEmpty)
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

        XCTAssertEqual(manager.pendingRequests.map(\.paymentRequestId), ["incoming", "accepted"])
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

    func testRefreshMapsActiveRecurringRequestAndCurrentUnpaidPeriod() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let record = try paymentRequestRecord(
            id: "recurring",
            state: .activeRecurring,
            recurrence: recurrence,
            metadata: #"{"note":"Mobile plan","subscription":{"version":1,"description":"10 GB every month","benefits":["Roaming"]}}"#
        )
        let manager = paymentRequestManager(
            sdk: PaymentRequestSdkMock(records: [record]),
            clock: PaymentRequestTestClock(now)
        )

        await manager.refresh()

        let subscription = try XCTUnwrap(manager.subscriptions.first)
        XCTAssertEqual(subscription.note, "Mobile plan")
        XCTAssertEqual(subscription.metadata.description, "10 GB every month")
        XCTAssertEqual(subscription.metadata.benefits, ["Roaming"])
        let request = try XCTUnwrap(manager.pendingRequests.first)
        XCTAssertEqual(request.paymentRequestId, "recurring")
        XCTAssertFalse(request.requiresAcceptance)
        XCTAssertEqual(request.billingPeriod?.startsAt, try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-01T08:00:00Z")))
        XCTAssertEqual(request.billingPeriod?.endsAt, try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-02-01T08:00:00Z")))
    }

    func testEndedSubscriptionKeepsItsUnpaidPeriodAvailable() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: "2027-01-10T08:00:00Z"
        )
        let record = try paymentRequestRecord(
            state: .activeRecurring,
            recurrence: recurrence,
            lastEventAt: "2027-01-01T08:00:00Z"
        )
        let manager = paymentRequestManager(
            sdk: PaymentRequestSdkMock(records: [record]),
            clock: PaymentRequestTestClock(now)
        )

        await manager.refresh()

        XCTAssertTrue(try XCTUnwrap(manager.subscriptions.first).isExpired(at: now))
        XCTAssertEqual(manager.pendingRequests.first?.billingPeriod?.endsAt, recurrence.endsAt.flatMap(PaykitPaymentRequest.parseDate))
    }

    func testAcceptingSubscriptionSurfacesCurrentPeriodAndCancelRemovesIt() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord(id: "recurring", recurrence: recurrence)])
        let manager = paymentRequestManager(sdk: sdk, clock: PaymentRequestTestClock(now))
        await manager.refresh()

        let subscription = try XCTUnwrap(manager.subscriptions.first)
        let dueRequest = try await manager.accept(subscription)

        XCTAssertEqual(dueRequest?.paymentRequestId, "recurring")
        let request = try XCTUnwrap(dueRequest)
        XCTAssertFalse(request.requiresAcceptance)
        try await manager.prepareForPayment(request)
        XCTAssertEqual(manager.pendingRequests, [request])
        XCTAssertTrue(manager.isApprovedForPayment(request))
        await manager.finishPayment(request)
        XCTAssertFalse(manager.isApprovedForPayment(request))
        try await manager.cancel(XCTUnwrap(manager.subscriptions.first))
        XCTAssertTrue(manager.subscriptions.isEmpty)
        XCTAssertTrue(manager.pendingRequests.isEmpty)
    }

    func testInitialSubscriptionPaymentRetryKeepsInitialPaymentSemantics() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let manager = try paymentRequestManager(
            sdk: PaymentRequestSdkMock(records: [paymentRequestRecord(state: .activeRecurring, recurrence: recurrence)]),
            clock: PaymentRequestTestClock(now)
        )
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)

        XCTAssertEqual(manager.paymentRequestForRetry(request.id), request)
        XCTAssertTrue(manager.requestPresentation(request, isInitialSubscriptionPayment: true))
        XCTAssertTrue(manager.isInitialSubscriptionPayment(request))
        XCTAssertTrue(manager.consumeInitialSubscriptionPayment(request))
        XCTAssertFalse(manager.isInitialSubscriptionPayment(request))
    }

    func testAcceptedRequestPastProposalExpirationDoesNotRescheduleExpiration() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = PaymentRequestTestClock(now)
        let record = try paymentRequestRecord(
            state: .accepted,
            expiresAt: timestamp(now.addingTimeInterval(-60))
        )
        let manager = paymentRequestManager(sdk: PaymentRequestSdkMock(records: [record]), clock: clock)

        await manager.refresh()

        XCTAssertEqual(manager.pendingRequests.count, 1)
        let baseline = clock.invocationCount()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertLessThan(clock.invocationCount() - baseline, 10)
        manager.clear()
    }

    func testAcceptingSubscriptionSelectsPeriodFromMatchingCounterpartyAndPath() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let first = try paymentRequestRecord(id: "shared", counterparty: "first", recurrence: recurrence)
        let second = try paymentRequestRecord(
            id: "shared",
            counterparty: "second",
            counterpartyReceiverPath: PaykitReceiverPath.wallet,
            recurrence: recurrence
        )
        let manager = paymentRequestManager(
            sdk: PaymentRequestSdkMock(records: [first, second]),
            clock: PaymentRequestTestClock(now)
        )
        await manager.refresh()

        let subscription = try XCTUnwrap(manager.subscriptions.first { $0.counterparty == "second" })
        let acceptedRequest = try await manager.accept(subscription)
        let dueRequest = try XCTUnwrap(acceptedRequest)

        XCTAssertEqual(dueRequest.counterparty, "second")
        XCTAssertEqual(dueRequest.counterpartyReceiverPath, PaykitReceiverPath.wallet)
    }

    func testAcceptingSubscriptionRejectsTermsChangedAfterReview() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord(recurrence: recurrence)])
        let manager = paymentRequestManager(sdk: sdk, clock: PaymentRequestTestClock(now))
        await manager.refresh()
        let reviewedSubscription = try XCTUnwrap(manager.subscriptions.first)

        try await sdk.setRecords([paymentRequestRecord(amount: "0.002", recurrence: recurrence)])
        await manager.refresh()

        do {
            _ = try await manager.accept(reviewedSubscription)
            XCTFail("Expected changed subscription terms to require another review")
        } catch {
            XCTAssertEqual(error as? PaykitPaymentRequestError, .requestUnavailable)
        }
        let snapshot = await sdk.snapshot()
        XCTAssertTrue(snapshot.acceptedRequests.isEmpty)
    }

    func testDismissedSubscriptionPeriodStaysOutOfQueueAfterRefresh() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let manager = try paymentRequestManager(
            sdk: PaymentRequestSdkMock(records: [paymentRequestRecord(state: .activeRecurring, recurrence: recurrence)]),
            clock: PaymentRequestTestClock(now)
        )
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)

        XCTAssertTrue(manager.dismissSubscriptionPayment(request))
        XCTAssertTrue(manager.pendingRequests.isEmpty)

        await manager.refresh()

        XCTAssertTrue(manager.pendingRequests.isEmpty)
    }

    func testCompletedSubscriptionPaymentAwaitingProofSubmissionIsNotOfferedAgain() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let record = try paymentRequestRecord(state: .activeRecurring, recurrence: recurrence)
        let subscription = try XCTUnwrap(PaykitSubscription(record: record))
        let request = try XCTUnwrap(subscription.requests(through: now, acceptedAt: now).first)
        let manager = paymentRequestManager(
            sdk: PaymentRequestSdkMock(records: [record]),
            clock: PaymentRequestTestClock(now),
            completedPaymentProofKinds: [request.id: .lightning]
        )

        await manager.refresh()

        XCTAssertTrue(manager.pendingRequests.isEmpty)
        XCTAssertEqual(manager.historyRequests.first?.id, request.id)
        XCTAssertEqual(manager.historyRequests.first?.lifecycleState, .proofSubmitted)
        XCTAssertEqual(manager.historyRequests.first?.paymentProofKind, .lightning)
    }

    func testCompletedOneTimePaymentAwaitingProofSubmissionKeepsPaymentProofKind() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let record = try paymentRequestRecord(state: .accepted)
        let request = try XCTUnwrap(PaykitPaymentRequest(historyRecord: record, now: now))

        for proofKind in [PaykitPaymentProofKind.lightning, .onchain] {
            let manager = paymentRequestManager(
                sdk: PaymentRequestSdkMock(records: [record]),
                clock: PaymentRequestTestClock(now),
                completedPaymentProofKinds: [request.id: proofKind]
            )

            await manager.refresh()

            XCTAssertTrue(manager.pendingRequests.isEmpty)
            XCTAssertEqual(manager.historyRequests.first?.id, request.id)
            XCTAssertEqual(manager.historyRequests.first?.lifecycleState, .proofSubmitted)
            XCTAssertEqual(manager.historyRequests.first?.paymentProofKind, proofKind)
        }
    }

    func testOneTimeHistoryKeepsPaymentProofKind() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let cases: [(PublicPaykitService.MethodId, PaykitPaymentProofKind)] = [
            (.bitcoinLightningBolt11, .lightning),
            (.regtestOnchainP2wpkh, .onchain),
        ]

        for (method, proofKind) in cases {
            let proof = try paymentProofRecord(endpoint: method.rawValue, kind: proofKind)
            let record = try paymentRequestRecord(
                state: .proofSubmitted,
                endpoints: [method.rawValue],
                paymentProofs: [proof]
            )
            let request = try XCTUnwrap(PaykitPaymentRequest(historyRecord: record, now: now))

            XCTAssertEqual(request.paymentProofKind, proofKind)
        }
    }

    func testInFlightSubscriptionPaymentIsNotOfferedOrMarkedPaid() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let record = try paymentRequestRecord(state: .activeRecurring, recurrence: recurrence)
        let subscription = try XCTUnwrap(PaykitSubscription(record: record))
        let request = try XCTUnwrap(subscription.paymentDueOnAcceptance(at: now))
        let manager = paymentRequestManager(
            sdk: PaymentRequestSdkMock(records: [record]),
            clock: PaymentRequestTestClock(now),
            inFlightPaymentRequestIds: [request.id]
        )

        await manager.refresh()

        XCTAssertTrue(manager.pendingRequests.isEmpty)
        XCTAssertTrue(manager.historyRequests.isEmpty)
    }

    func testSubscriptionCannotBeCanceledWhilePaymentProofIsPending() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let record = try paymentRequestRecord(state: .activeRecurring, recurrence: recurrence)
        let subscription = try XCTUnwrap(PaykitSubscription(record: record))
        let request = try XCTUnwrap(subscription.paymentDueOnAcceptance(at: now))
        let manager = paymentRequestManager(
            sdk: PaymentRequestSdkMock(records: [record]),
            clock: PaymentRequestTestClock(now),
            protectedRequestIdsForSubscriptionCancellation: [request.id]
        )

        await manager.refresh()
        do {
            try await manager.cancel(XCTUnwrap(manager.subscriptions.first))
            XCTFail("Expected cancellation to wait for the pending proof")
        } catch {
            XCTAssertEqual(error as? PaykitPaymentRequestError, .operationInProgress)
        }

        XCTAssertEqual(manager.subscriptions.count, 1)
    }

    func testSubscriptionCancellationDoesNotUseStaleIdentityAfterClear() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let record = try paymentRequestRecord(state: .activeRecurring, recurrence: recurrence)
        let sdk = PaymentRequestSdkMock(records: [record])
        let gate = PaymentProofProtectionGate()
        let manager = PaykitPaymentRequestManager(
            service: PaykitPaymentRequestService(sdk: sdk, now: { now }, logWarning: { _ in }),
            presentationStore: PaymentRequestPresentationMemoryStore(),
            subscriptionStateStore: PaymentRequestSubscriptionStateMemoryStore(),
            protectedRequestIdsForSubscriptionCancellation: { _, _ in await gate.wait() },
            now: { now },
            isAvailable: { true },
            logWarning: { _ in }
        )
        manager.activate(identity: "pubky\(String(repeating: "z", count: 52))")
        await manager.refresh()
        let subscription = try XCTUnwrap(manager.subscriptions.first)

        let cancellation = Task { try await manager.cancel(subscription) }
        try await waitUntil { await gate.isWaiting }
        manager.clear()
        manager.activate(identity: "pubky\(String(repeating: "a", count: 52))")
        await gate.resume()
        try await cancellation.value

        let remainingRecords = await sdk.paymentRequests()
        XCTAssertEqual(remainingRecords.count, 1)
    }

    func testActiveSubscriptionTransitionUsesNextPeriodBoundary() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let weekly = PaymentRequestRecurrence(
            every: 1,
            unit: "week",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let yearly = PaymentRequestRecurrence(
            every: 1,
            unit: "year",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let weeklySubscription = try XCTUnwrap(PaykitSubscription(record: paymentRequestRecord(state: .activeRecurring, recurrence: weekly)))
        let yearlySubscription = try XCTUnwrap(PaykitSubscription(record: paymentRequestRecord(state: .activeRecurring, recurrence: yearly)))

        XCTAssertEqual(
            subscriptionNextTransitionDate(subscriptions: [weeklySubscription], now: now),
            ISO8601DateFormatter().date(from: "2027-01-22T08:00:00Z")
        )
        XCTAssertEqual(
            subscriptionNextTransitionDate(subscriptions: [yearlySubscription], now: now),
            ISO8601DateFormatter().date(from: "2028-01-01T08:00:00Z")
        )
    }

    func testMonthlySubscriptionCostNormalizesRecurrenceFrequencies() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let cases: [(unit: String, every: UInt32, amount: String, expectedSats: Int)] = [
            ("day", 1, "0.000012", 36500),
            ("week", 1, "0.000012", 5200),
            ("month", 1, "0.000012", 1200),
            ("month", 2, "0.000012", 600),
            ("year", 1, "0.000012", 100),
        ]

        for testCase in cases {
            let recurrence = PaymentRequestRecurrence(
                every: testCase.every,
                unit: testCase.unit,
                startsAt: "2027-01-01T08:00:00Z",
                anchor: "2027-01-01T08:00:00Z",
                endsAt: nil
            )
            let subscription = try XCTUnwrap(PaykitSubscription(record: paymentRequestRecord(
                state: .activeRecurring,
                amount: testCase.amount,
                recurrence: recurrence
            )))

            XCTAssertEqual(
                subscriptionMonthlyCostSats(subscriptions: [subscription], now: now),
                testCase.expectedSats,
                "Unexpected monthly cost for every \(testCase.every) \(testCase.unit)"
            )
        }

        let lowCostYearlySubscriptions = try (0 ..< 3).map { index in
            try XCTUnwrap(PaykitSubscription(record: paymentRequestRecord(
                id: "low-cost-\(index)",
                state: .activeRecurring,
                amount: "0.0000001",
                recurrence: PaymentRequestRecurrence(
                    every: 1,
                    unit: "year",
                    startsAt: "2027-01-01T08:00:00Z",
                    anchor: "2027-01-01T08:00:00Z",
                    endsAt: nil
                )
            )))
        }
        XCTAssertEqual(subscriptionMonthlyCostSats(subscriptions: lowCostYearlySubscriptions, now: now), 3)
    }

    func testMonthlySubscriptionCostIncludesPaidActiveSubscriptionsOnly() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let paidPeriod = BillingPeriod(
            startsAt: "2027-01-01T08:00:00Z",
            endsAt: "2027-02-01T08:00:00Z"
        )
        let paidActive = try XCTUnwrap(PaykitSubscription(record: paymentRequestRecord(
            state: .activeRecurring,
            amount: "0.000012",
            recurrence: recurrence,
            paymentProofs: [paymentProofRecord(
                endpoint: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                kind: .lightning,
                billingPeriod: paidPeriod
            )]
        )))
        let canceled = try XCTUnwrap(PaykitSubscription(record: paymentRequestRecord(
            state: .canceled,
            amount: "0.000012",
            recurrence: recurrence
        )))
        let proposed = try XCTUnwrap(PaykitSubscription(record: paymentRequestRecord(
            state: .proposed,
            amount: "0.000012",
            recurrence: recurrence
        )))

        XCTAssertEqual(
            subscriptionMonthlyCostSats(subscriptions: [paidActive, canceled, proposed], now: now),
            1200
        )
    }

    func testCommittedSubscriptionAcceptanceSurvivesImmediateRefreshFailure() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord(id: "recurring", recurrence: recurrence)])
        let manager = paymentRequestManager(sdk: sdk, clock: PaymentRequestTestClock(now))
        await manager.refresh()
        await sdk.setReceiveError(.receive)

        let request = try await manager.accept(XCTUnwrap(manager.subscriptions.first))

        XCTAssertEqual(manager.subscriptions.first?.lifecycleState, .activeRecurring)
        XCTAssertEqual(request, manager.pendingRequests.first)
    }

    func testSubscriptionAcceptanceCompletionAfterClearDoesNotRepopulateManager() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord(id: "recurring", recurrence: recurrence)])
        let manager = paymentRequestManager(sdk: sdk, clock: PaymentRequestTestClock(now))
        await manager.refresh()
        await sdk.pauseNextAccept()

        let acceptance = Task {
            try await manager.accept(XCTUnwrap(manager.subscriptions.first))
        }
        try await waitUntil { await sdk.acceptIsPaused() }
        manager.clear()
        await sdk.resumeAccept()

        let dueRequest = try await acceptance.value
        XCTAssertNil(dueRequest)
        XCTAssertTrue(manager.subscriptions.isEmpty)
        XCTAssertTrue(manager.pendingRequests.isEmpty)
    }

    func testMonthlyRecurrenceKeepsAnchorDayAfterShortMonth() throws {
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-31T08:00:00Z",
            anchor: "2027-01-31T08:00:00Z",
            endsAt: nil
        )
        let schedule = try XCTUnwrap(PaykitSubscriptionRecurrence(recurrence))
        let acceptedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-31T08:00:00Z"))
        let through = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-03-15T08:00:00Z"))

        let periods = schedule.periods(through: through, acceptedAt: acceptedAt)

        XCTAssertEqual(periods.count, 2)
        XCTAssertEqual(periods[0].endsAt, try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-02-28T08:00:00Z")))
        XCTAssertEqual(periods[1].endsAt, try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-03-31T08:00:00Z")))
    }

    func testRecurrenceUsesFirstAnchorBoundaryAfterStart() throws {
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-15T08:00:00Z",
            endsAt: nil
        )
        let schedule = try XCTUnwrap(PaykitSubscriptionRecurrence(recurrence))
        let acceptedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-01T08:00:00Z"))
        let through = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-10T08:00:00Z"))

        let period = try XCTUnwrap(schedule.periods(through: through, acceptedAt: acceptedAt).first)

        XCTAssertEqual(period.startsAt, acceptedAt)
        XCTAssertEqual(period.endsAt, try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z")))
    }

    func testRecurrenceReturnsConsecutiveUpcomingPeriods() throws {
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "week",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let schedule = try XCTUnwrap(PaykitSubscriptionRecurrence(recurrence))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-02T08:00:00Z"))

        let periods = schedule.upcomingPeriods(after: now, limit: 3)

        XCTAssertEqual(periods.map(\.startsAt), try [
            XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-08T08:00:00Z")),
            XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z")),
            XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-22T08:00:00Z")),
        ])
    }

    func testOldDailyRecurrenceFindsNextPeriodDirectly() throws {
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "day",
            startsAt: "2020-01-01T08:00:00Z",
            anchor: "2020-01-01T08:00:00Z",
            endsAt: nil
        )
        let schedule = try XCTUnwrap(PaykitSubscriptionRecurrence(recurrence))
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-14T12:00:00Z"))

        let period = try XCTUnwrap(schedule.nextPeriod(after: date))

        XCTAssertEqual(period.startsAt, try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z")))
        XCTAssertEqual(period.endsAt, try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-16T08:00:00Z")))
    }

    func testRecurrencePreservesNanosecondBillingBoundaries() throws {
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "day",
            startsAt: "2027-01-01T08:00:00.123100Z",
            anchor: "2027-01-01T08:00:00.123900Z",
            endsAt: nil
        )
        let schedule = try XCTUnwrap(PaykitSubscriptionRecurrence(recurrence))
        let through = try XCTUnwrap(PaykitPaymentRequest.parseDate("2027-01-01T08:00:01Z"))
        let acceptedAt = try XCTUnwrap(PaykitPaymentRequest.parseDate("2027-01-01T08:00:00Z"))

        let period = try XCTUnwrap(schedule.periods(through: through, acceptedAt: acceptedAt).first)

        XCTAssertEqual(period.sdkValue.startsAt, "2027-01-01T08:00:00.123100Z")
        XCTAssertEqual(period.sdkValue.endsAt, "2027-01-01T08:00:00.123900Z")
    }

    func testSubscriptionTimestampsPreserveFractionalOffset() throws {
        let startsAt = "2027-01-01T08:00:00.500+01:00"
        let endsAt = "2027-02-01T08:00:00.500+01:00"
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: startsAt,
            anchor: startsAt,
            endsAt: nil
        )
        let schedule = try XCTUnwrap(PaykitSubscriptionRecurrence(recurrence))
        let expectedStart = try XCTUnwrap(PaykitPaymentRequest.parseDate("2027-01-01T07:00:00.500Z"))
        let period = try XCTUnwrap(PaykitBillingPeriod(sdkPeriod: BillingPeriod(startsAt: startsAt, endsAt: endsAt)))

        XCTAssertEqual(schedule.startsAt.timeIntervalSince1970, expectedStart.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(period.startsAt.timeIntervalSince1970, expectedStart.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(period.sdkValue.startsAt, startsAt)
    }

    func testSubscriptionTimestampUsesCanonicalInstantPrecision() {
        XCTAssertEqual(PaykitSubscriptionTimestamp.canonical("2027-01-01T08:00:00.1Z"), "2027-01-01T08:00:00.100Z")
        XCTAssertEqual(PaykitSubscriptionTimestamp.canonical("2027-01-01T08:00:00.1000Z"), "2027-01-01T08:00:00.100Z")
        XCTAssertEqual(
            PaykitSubscriptionTimestamp.canonical("2027-01-01T08:00:00.123456789Z"),
            "2027-01-01T08:00:00.123456789Z"
        )
    }

    func testRecurrenceDoesNotInventPeriodWhenAnchorSearchExceedsLimit() throws {
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "day",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2077-01-01T08:00:00Z",
            endsAt: nil
        )
        let schedule = try XCTUnwrap(PaykitSubscriptionRecurrence(recurrence))
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-01T08:00:00Z"))

        XCTAssertTrue(schedule.periods(through: start, acceptedAt: start).isEmpty)
        XCTAssertFalse(schedule.canMaterializePeriods)
    }

    func testRecurringProposalRejectsMalformedExpiryAndDisablesUnsupportedPaymentDetails() async throws {
        let expiration = Date(timeIntervalSince1970: 1_800_000_000)
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let endedRecurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: timestamp(expiration)
        )
        let manager = try paymentRequestManager(
            sdk: PaymentRequestSdkMock(records: [
                paymentRequestRecord(id: "malformed", expiresAt: "not-a-timestamp", recurrence: recurrence),
                paymentRequestRecord(id: "unsupported", recurrence: recurrence, endpoints: ["btc-unsupported-method"]),
                paymentRequestRecord(id: "ended", recurrence: endedRecurrence),
            ]),
            clock: PaymentRequestTestClock(expiration)
        )

        await manager.refresh()

        let subscription = try XCTUnwrap(manager.subscriptions.first)
        XCTAssertEqual(subscription.paymentRequestId, "unsupported")
        XCTAssertFalse(subscription.isProposalActionable(at: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertEqual(manager.subscriptionProposalForPresentation()?.id, subscription.id)
        XCTAssertEqual(
            manager.subscriptions.first { $0.paymentRequestId == "ended" }?.lifecycleState,
            .proposalExpired
        )
        XCTAssertFalse(manager.subscriptions.first { $0.paymentRequestId == "ended" }?.isProposalActionable(at: expiration) ?? true)

        let expiring = try XCTUnwrap(PaykitSubscription(record: paymentRequestRecord(
            id: "expiring",
            expiresAt: timestamp(expiration),
            recurrence: recurrence
        )))
        XCTAssertEqual(expiring.withExpiredLifecycle(at: expiration).lifecycleState, .proposalExpired)
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
            subscriptionStateStore: PaymentRequestSubscriptionStateMemoryStore(),
            completedPaymentProofKinds: { _ in [:] },
            now: now,
            logWarning: { _ in }
        )
        manager.activate(identity: "pubky\(String(repeating: "z", count: 52))")
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
            manager.deferPresentation(request)
            XCTAssertTrue(manager.requestsForPresentation().isEmpty)
            clock.advance(by: 2)
            XCTAssertEqual(manager.requestsForPresentation(), [request])
        }

        manager.deferPresentation(request)
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
            manager.deferPresentation(request)
            XCTAssertTrue(manager.requestsForPresentation().isEmpty)
            clock.advance(by: 2)
            XCTAssertEqual(manager.requestsForPresentation(), [request])
        }

        manager.deferPresentation(request)

        XCTAssertTrue(manager.requestsForPresentation().isEmpty)
        XCTAssertNil(manager.requestedPresentationId)
        XCTAssertEqual(manager.pendingRequests, [request])
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

    func testAcceptedRequestRemainsRetryableAfterSendFlowFinishes() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)

        try await manager.prepareForPayment(request)

        XCTAssertTrue(manager.isApprovedForPayment(request))
        await manager.finishPayment(request)
        XCTAssertFalse(manager.isApprovedForPayment(request))
        XCTAssertEqual(manager.pendingRequests, [request.updatingLifecycleState(.accepted)])
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
        let subscriptionStore = PaymentRequestSubscriptionStateMemoryStore()
        let firstManager = PaykitPaymentRequestManager(
            service: PaykitPaymentRequestService(sdk: sdk, logWarning: { _ in }),
            presentationStore: store,
            subscriptionStateStore: subscriptionStore,
            logWarning: { _ in }
        )
        firstManager.activate(identity: identity)
        await firstManager.refresh()
        let request = try XCTUnwrap(firstManager.pendingRequests.first)
        XCTAssertTrue(firstManager.markPresentedIfPending(request))

        let restoredManager = PaykitPaymentRequestManager(
            service: PaykitPaymentRequestService(sdk: sdk, logWarning: { _ in }),
            presentationStore: store,
            subscriptionStateStore: subscriptionStore,
            logWarning: { _ in }
        )
        restoredManager.activate(identity: identity)
        await restoredManager.refresh()

        XCTAssertEqual(restoredManager.pendingRequests, [request])
        XCTAssertTrue(restoredManager.requestsForPresentation().isEmpty)
        XCTAssertTrue(restoredManager.requestPresentation(request))
        XCTAssertEqual(restoredManager.requestsForPresentation(), [request])
    }

    func testPresentedSubscriptionStaysAvailableWithoutAutoPresentingAfterManagerRecreation() async throws {
        let identity = "pubky\(String(repeating: "y", count: 52))"
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord(id: "subscription", recurrence: recurrence)])
        let presentationStore = PaymentRequestPresentationMemoryStore()
        let subscriptionStore = PaymentRequestSubscriptionStateMemoryStore()
        let firstManager = PaykitPaymentRequestManager(
            service: PaykitPaymentRequestService(sdk: sdk, logWarning: { _ in }),
            presentationStore: presentationStore,
            subscriptionStateStore: subscriptionStore,
            logWarning: { _ in }
        )
        firstManager.activate(identity: identity)
        await firstManager.refresh()
        let subscription = try XCTUnwrap(firstManager.subscriptionProposalForPresentation())
        firstManager.markSubscriptionProposalPresented(subscription)

        let restoredManager = PaykitPaymentRequestManager(
            service: PaykitPaymentRequestService(sdk: sdk, logWarning: { _ in }),
            presentationStore: presentationStore,
            subscriptionStateStore: subscriptionStore,
            logWarning: { _ in }
        )
        restoredManager.activate(identity: identity)
        await restoredManager.refresh()

        let restoredSubscription = try XCTUnwrap(restoredManager.subscriptions.first)
        XCTAssertNil(restoredManager.subscriptionProposalForPresentation())
        restoredManager.requestSubscriptionPresentation(restoredSubscription)
        XCTAssertEqual(restoredManager.subscriptionProposalForPresentation(), restoredSubscription)
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
            subscriptionStateStore: PaymentRequestSubscriptionStateMemoryStore(),
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
        isPrivatePaymentPublishingEnabled: Bool = true,
        completedPaymentProofKinds: [PaykitPaymentRequest.ID: PaykitPaymentProofKind] = [:],
        inFlightPaymentRequestIds: Set<PaykitPaymentRequest.ID> = [],
        protectedRequestIdsForSubscriptionCancellation: Set<PaykitPaymentRequest.ID> = []
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
            subscriptionStateStore: PaymentRequestSubscriptionStateMemoryStore(),
            completedPaymentProofKinds: { _ in completedPaymentProofKinds },
            inFlightPaymentRequestIds: { _ in inFlightPaymentRequestIds },
            protectedRequestIdsForSubscriptionCancellation: { _, _ in protectedRequestIdsForSubscriptionCancellation },
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
        lastEventAt: String = "2027-01-15T08:00:00Z",
        proposalOutboundMessageId: UInt64? = nil,
        proposalOutboundStatus: OutboundPrivateMessageStatus? = nil,
        acceptedEventId: String? = nil,
        paymentProofs: [PaymentProofRecord] = []
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
            acceptedEventId: acceptedEventId,
            acceptedOutboundStatus: nil,
            rejectedEventId: nil,
            rejectedOutboundStatus: nil,
            canceledEventId: nil,
            canceledOutboundStatus: nil,
            paymentProofs: paymentProofs,
            lastStreamItemId: 1,
            lastOutboundMessageId: nil,
            lastOutboundStatus: nil,
            lastEventAt: lastEventAt,
            invalidReason: nil
        )
    }

    private func paymentProofRecord(
        endpoint: String,
        kind: PaykitPaymentProofKind,
        billingPeriod: BillingPeriod? = nil
    ) throws -> PaymentProofRecord {
        try PaymentProofRecord(
            eventId: "750e8400-e29b-41d4-a716-446655440000",
            outboundMessageId: nil,
            outboundStatus: nil,
            streamItemId: 2,
            paymentReference: PaymentReference(text: "invoice-123"),
            billingPeriod: billingPeriod,
            paymentEndpointIdentifier: endpoint,
            proof: PrivateJsonObject(text: "{\"data\":\"proof\",\"type\":\"\(kind.rawValue)\"}"),
            recordedAt: "2027-01-15T08:01:00Z"
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

private final class PaymentRequestSubscriptionStateMemoryStore: PaykitSubscriptionStateStoring {
    private var states: [String: PaykitSubscriptionState] = [:]

    func load(identity: String) -> PaykitSubscriptionState {
        states[identity] ?? PaykitSubscriptionState()
    }

    func save(_ subscriptionState: PaykitSubscriptionState, identity: String) {
        states[identity] = subscriptionState
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

        let record: PaymentRequestRecord
        if let index = records.firstIndex(where: {
            $0.counterparty == counterparty &&
                $0.counterpartyReceiverPath == counterpartyReceiverPath &&
                $0.paymentRequestId == paymentRequestId &&
                $0.terms?.recurrence != nil
        }) {
            records[index].state = .activeRecurring
            record = records[index]
        } else {
            record = try removeRecord(
                counterparty: counterparty,
                counterpartyReceiverPath: counterpartyReceiverPath,
                id: paymentRequestId
            )
        }
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

    func cancelPaymentRequest(
        counterparty: String,
        counterpartyReceiverPath: String,
        paymentRequestId: String,
        reason _: String?
    ) throws -> PaymentRequestRecord {
        try removeRecord(
            counterparty: counterparty,
            counterpartyReceiverPath: counterpartyReceiverPath,
            id: paymentRequestId
        )
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
    private var invocations = 0

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        invocations += 1
        return date
    }

    func invocationCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return invocations
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

private actor PaymentProofProtectionGate {
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool {
        continuation != nil
    }

    func wait() async -> Set<PaykitPaymentRequest.ID> {
        await withCheckedContinuation { continuation = $0 }
        return []
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor PaykitSubscriptionNotificationCenterMock: PaykitSubscriptionNotificationCenter {
    private var requests: [String: UNNotificationRequest] = [:]
    private var shouldPauseNextAdd = false
    private var addContinuation: CheckedContinuation<Void, Never>?

    var isAddPaused: Bool {
        addContinuation != nil
    }

    var pendingIdentifiers: Set<String> {
        Set(requests.keys)
    }

    func pauseNextAdd() {
        shouldPauseNextAdd = true
    }

    func pendingNotificationRequests() -> [UNNotificationRequest] {
        Array(requests.values)
    }

    func add(_ request: UNNotificationRequest) async throws {
        if shouldPauseNextAdd {
            shouldPauseNextAdd = false
            await withCheckedContinuation { addContinuation = $0 }
        }
        requests[request.identifier] = request
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        for identifier in identifiers {
            requests.removeValue(forKey: identifier)
        }
    }

    func resumeAdd() {
        addContinuation?.resume()
        addContinuation = nil
    }
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
