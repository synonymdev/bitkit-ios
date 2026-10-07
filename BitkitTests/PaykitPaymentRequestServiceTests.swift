@testable import Bitkit
import BitkitCore
import Foundation
import LDKNode
import Observation
import Paykit
import UIKit
import UserNotifications
import XCTest

@MainActor
final class PaykitPaymentRequestServiceTests: XCTestCase {
    func testRefreshModesLoadStoredRequestsAndControlPrivateMessageSync() async throws {
        let stored = try paymentRequestRecord(id: "stored")
        let incoming = try paymentRequestRecord(id: "incoming")
        let modes: [PaykitPaymentRequestRefreshMode] = [.stored, .inbox, .full]
        for mode in modes {
            for priority in [PaykitSdkOperationLock.Priority.ordered, .background] {
                let context = "\(mode), \(priority)"
                let sdk = PaymentRequestSdkMock(records: [stored])
                await sdk.setIncomingRecords([incoming])
                let manager = paymentRequestManager(sdk: sdk)

                if priority == .ordered {
                    await manager.refresh(mode: mode)
                } else {
                    await manager.refresh(mode: mode, messagePriority: priority)
                }

                let expectedIds = mode == .stored ? [stored.paymentRequestId] : [stored.paymentRequestId, incoming.paymentRequestId]
                XCTAssertEqual(Set(manager.pendingRequests.map(\.paymentRequestId)), Set(expectedIds), context)
                let snapshot = await sdk.snapshot()
                XCTAssertEqual(snapshot.processCallCount, mode == .full ? 1 : 0, context)
                XCTAssertEqual(snapshot.receiveCallCount, mode >= .inbox ? 1 : 0, context)
                XCTAssertEqual(snapshot.paymentRequestListCallCount, 1, context)
                let priorities = await sdk.operationPriorities
                XCTAssertEqual(priorities["pending"] ?? [], mode == .full ? [priority] : [], context)
                XCTAssertEqual(priorities["receive"] ?? [], mode >= .inbox ? [priority] : [], context)
                XCTAssertEqual(priorities["requests"], [.background], context)
                XCTAssertEqual(priorities["peers"], [.background], context)
            }
        }
    }

    func testOverlappingRefreshesUpgradeOnlyForStrongerModes() async throws {
        let modes: [PaykitPaymentRequestRefreshMode] = [.stored, .inbox, .full]
        for initialMode in modes {
            for requestedMode in modes {
                let context = "\(initialMode) then \(requestedMode)"
                let sdk = PaymentRequestSdkMock(records: [])
                let manager = paymentRequestManager(sdk: sdk)
                await sdk.pauseNextPaymentRequestList()
                let initialRefresh = Task { await manager.refresh(mode: initialMode, messagePriority: .background) }
                try await waitUntil { await sdk.paymentRequestListIsPaused() }
                let overlappingRefreshStarted = expectation(description: context)
                let overlappingRefresh = Task {
                    overlappingRefreshStarted.fulfill()
                    return await manager.refresh(mode: requestedMode)
                }
                await fulfillment(of: [overlappingRefreshStarted], timeout: 1)

                let pausedSnapshot = await sdk.snapshot()
                XCTAssertEqual(pausedSnapshot.processCallCount, initialMode == .full ? 1 : 0, context)
                XCTAssertEqual(pausedSnapshot.receiveCallCount, initialMode >= .inbox ? 1 : 0, context)
                XCTAssertEqual(pausedSnapshot.paymentRequestListCallCount, 1, context)
                await sdk.resumePaymentRequestList()
                let initialSucceeded = await initialRefresh.value
                let overlappingSucceeded = await overlappingRefresh.value
                XCTAssertTrue(initialSucceeded, context)
                XCTAssertTrue(overlappingSucceeded, context)

                let upgrades = requestedMode > initialMode
                let snapshot = await sdk.snapshot()
                XCTAssertEqual(snapshot.processCallCount, max(initialMode, requestedMode) == .full ? 1 : 0, context)
                XCTAssertEqual(snapshot.receiveCallCount, (initialMode >= .inbox ? 1 : 0) + (upgrades ? 1 : 0), context)
                XCTAssertEqual(snapshot.paymentRequestListCallCount, upgrades ? 2 : 1, context)
                let priorities = await sdk.operationPriorities
                XCTAssertEqual(
                    priorities["pending"] ?? [],
                    initialMode == .full ? [.background] : requestedMode == .full ? [.ordered] : [],
                    context
                )
                XCTAssertEqual(
                    priorities["receive"] ?? [],
                    (initialMode >= .inbox ? [.background] : []) + (upgrades ? [.ordered] : []),
                    context
                )
            }
        }
    }

    func testStoredRefreshReportsCoalescedFailureBeforeLoadingSubscriptions() async throws {
        defer { PaykitSubscriptionNotificationTargetStore.clear() }
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1, unit: "month", startsAt: timestamp(now), anchor: timestamp(now), endsAt: nil
        )
        let record = try paymentRequestRecord(
            counterparty: "pubky\(String(repeating: "y", count: 52))", state: .activeRecurring, recurrence: recurrence
        )
        let target = try XCTUnwrap(PaykitSubscriptionNotificationTarget(userInfo: [
            "payer_identity": "pubky\(String(repeating: "z", count: 52))",
            "payment_request_id": record.paymentRequestId,
            "counterparty": record.counterparty,
            "billing_period_starts_at": PaykitSubscriptionTimestamp.string(from: now),
        ]))
        PaykitSubscriptionNotificationTargetStore.save(target)
        let sdk = PaymentRequestSdkMock(records: [record])
        let manager = paymentRequestManager(sdk: sdk, clock: PaymentRequestTestClock(now))
        await sdk.setReceiveError(.receive)
        await sdk.pauseNextProcess()
        let fullRefresh = Task { await manager.refresh() }
        try await waitUntil { await sdk.processIsPaused() }

        let storedRefreshStarted = expectation(description: "Stored subscription refresh started")
        let storedRefresh = Task {
            storedRefreshStarted.fulfill()
            return await manager.refresh(mode: .stored)
        }
        await fulfillment(of: [storedRefreshStarted], timeout: 1)
        await sdk.resumeProcess()
        let fullSucceeded = await fullRefresh.value
        let storedSucceeded = await storedRefresh.value

        XCTAssertFalse(fullSucceeded)
        XCTAssertFalse(storedSucceeded)
        XCTAssertEqual(PaykitSubscriptionNotificationTargetStore.load(), target)
        XCTAssertTrue(manager.subscriptions.isEmpty)
        let failedSnapshot = await sdk.snapshot()
        XCTAssertEqual(failedSnapshot.paymentRequestListCallCount, 0)

        let retrySucceeded = await manager.refresh(mode: .stored)
        XCTAssertTrue(retrySucceeded)
        let request = try XCTUnwrap(manager.pendingRequests.first)
        XCTAssertEqual(request.paymentRequestId, record.paymentRequestId)
        XCTAssertNotNil(request.billingPeriod)
        XCTAssertTrue(target.matches(request))
        XCTAssertTrue(manager.markPresentedIfPending(request))
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)
        XCTAssertTrue(manager.requestPresentation(request))
        XCTAssertNil(PaykitSubscriptionNotificationTargetStore.load())
        XCTAssertEqual(manager.requestsForPresentation(), [request])
        XCTAssertEqual(manager.deferPresentation(request), .retryScheduled)
        PaykitSubscriptionNotificationTargetStore.save(target)
        manager.dismissPreparingRequest(request)
        XCTAssertNil(PaykitSubscriptionNotificationTargetStore.load())
        XCTAssertEqual(manager.pendingRequests, [request])
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)
        XCTAssertTrue(manager.requestPresentation(request))
    }

    func testFreshRefreshRereadsRequestsChangedAfterSnapshot() async throws {
        let record = try paymentRequestRecord()
        let sdk = PaymentRequestSdkMock(records: [record])
        let manager = paymentRequestManager(sdk: sdk)
        await sdk.pauseNextPaymentRequestList()
        let first = Task { await manager.refresh(messagePriority: .background) }
        try await waitUntil { await sdk.paymentRequestListIsPaused() }

        await sdk.setRecords([])
        let refreshStarted = expectation(description: "Request state refresh started")
        let fresh = Task {
            refreshStarted.fulfill()
            await manager.refresh(forceFresh: true, messagePriority: .background)
        }
        await fulfillment(of: [refreshStarted], timeout: 1)
        await sdk.resumePaymentRequestList()
        _ = await first.value
        await fresh.value

        XCTAssertTrue(manager.pendingRequests.isEmpty)
        let snapshot = await sdk.snapshot()
        XCTAssertEqual(snapshot.paymentRequestListCallCount, 2)
        let priorities = await sdk.operationPriorities
        XCTAssertEqual(priorities["pending"], [.background, .ordered])
        XCTAssertEqual(priorities["receive"], [.background, .ordered])
    }

    func testFreshRefreshRereadsProofStateChangedDuringNotificationSynchronization() async throws {
        actor InFlightPayments {
            var ids: Set<PaykitPaymentRequest.ID>

            init(_ id: PaykitPaymentRequest.ID) {
                ids = [id]
            }

            func clear() {
                ids = []
            }
        }

        let record = try paymentRequestRecord()
        let requestId = PaykitPaymentRequest.ID(paymentRequestId: record.paymentRequestId, counterparty: record.counterparty)
        let sdk = PaymentRequestSdkMock(records: [record])
        let inFlightPayments = InFlightPayments(requestId)
        let center = PaykitSubscriptionNotificationCenterMock()
        let manager = PaykitPaymentRequestManager(
            scheduleAcceptedRequestDelivery: { _ in },
            service: PaykitPaymentRequestService(sdk: sdk, logWarning: { _ in }),
            presentationStore: PaymentRequestPresentationMemoryStore(),
            acceptanceStore: PaymentRequestPresentationMemoryStore(),
            subscriptionStateStore: PaymentRequestSubscriptionStateMemoryStore(),
            subscriptionNotificationScheduler: PaykitSubscriptionNotificationScheduler(center: center),
            completedPaymentProofKinds: { _ in [:] },
            inFlightPaymentRequestIds: { _ in await inFlightPayments.ids },
            isAvailable: { true },
            logWarning: { _ in }
        )
        manager.activate(identity: "pubky\(String(repeating: "z", count: 52))")
        await center.pauseNextPendingRequests()
        let first = Task { await manager.refresh() }
        try await waitUntil { await center.isPendingRequestsPaused }
        XCTAssertTrue(manager.pendingRequests.isEmpty)

        await inFlightPayments.clear()
        let refreshStarted = expectation(description: "Proof state refresh started")
        let afterFailure = Task {
            refreshStarted.fulfill()
            await manager.refresh(mode: .stored, forceFresh: true)
        }
        await fulfillment(of: [refreshStarted], timeout: 1)
        await center.resumePendingRequests()
        _ = await first.value
        await afterFailure.value

        XCTAssertEqual(manager.pendingRequests.map(\.id), [requestId])
        let snapshot = await sdk.snapshot()
        XCTAssertEqual(snapshot.paymentRequestListCallCount, 2)
        XCTAssertEqual(snapshot.processCallCount, 1)
        XCTAssertEqual(snapshot.receiveCallCount, 1)
    }

    func testClearInvalidatesStrongerRefreshWaitingForWeakerMode() async throws {
        let modes: [PaykitPaymentRequestRefreshMode] = [.stored, .inbox, .full]
        for initialMode in modes {
            for requestedMode in modes where requestedMode > initialMode {
                let context = "\(initialMode) then \(requestedMode)"
                let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
                let manager = paymentRequestManager(sdk: sdk)
                await sdk.pauseNextPaymentRequestList()
                let initialRefresh = Task { await manager.refresh(mode: initialMode) }
                try await waitUntil { await sdk.paymentRequestListIsPaused() }
                let overlappingRefreshStarted = expectation(description: context)
                let overlappingRefresh = Task {
                    overlappingRefreshStarted.fulfill()
                    await manager.refresh(mode: requestedMode)
                }
                await fulfillment(of: [overlappingRefreshStarted], timeout: 1)

                manager.clear()
                await sdk.resumePaymentRequestList()
                _ = await initialRefresh.value
                await overlappingRefresh.value

                XCTAssertTrue(manager.pendingRequests.isEmpty, context)
                XCTAssertTrue(manager.historyRequests.isEmpty, context)
                let snapshot = await sdk.snapshot()
                XCTAssertEqual(snapshot.processCallCount, 0, context)
                XCTAssertEqual(snapshot.receiveCallCount, initialMode == .inbox ? 1 : 0, context)
                XCTAssertEqual(snapshot.paymentRequestListCallCount, 1, context)
            }
        }
    }

    func testCanceledRefreshDoesNotUpgradeInFlightStoredRefresh() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await sdk.pauseNextPaymentRequestList()
        let storedRefresh = Task { await manager.refresh(mode: .stored) }
        try await waitUntil { await sdk.paymentRequestListIsPaused() }
        let fullRefreshStarted = expectation(description: "Full refresh started")
        let fullRefresh = Task {
            fullRefreshStarted.fulfill()
            await manager.refresh()
        }
        await fulfillment(of: [fullRefreshStarted], timeout: 1)

        fullRefresh.cancel()
        await sdk.resumePaymentRequestList()
        _ = await storedRefresh.value
        await fullRefresh.value

        XCTAssertEqual(manager.pendingRequests.count, 1)
        let snapshot = await sdk.snapshot()
        XCTAssertEqual(snapshot.processCallCount, 0)
        XCTAssertEqual(snapshot.receiveCallCount, 0)
        XCTAssertEqual(snapshot.paymentRequestListCallCount, 1)
    }

    func testFreshRefreshDoesNotOutliveCancellationOrIdentityChange() async throws {
        for invalidation in ["cancel", "clear", "identity"] {
            let sdk = PaymentRequestSdkMock(records: [])
            let manager = paymentRequestManager(sdk: sdk)
            await sdk.pauseNextPaymentRequestList()
            let first = Task { await manager.refresh() }
            try await waitUntil { await sdk.paymentRequestListIsPaused() }
            let refreshStarted = expectation(description: invalidation)
            let fresh = Task {
                refreshStarted.fulfill()
                await manager.refresh(forceFresh: true)
            }
            await fulfillment(of: [refreshStarted], timeout: 1)

            switch invalidation {
            case "cancel": fresh.cancel()
            case "clear": manager.clear()
            default: manager.activate(identity: "pubky\(String(repeating: "y", count: 52))")
            }
            await sdk.resumePaymentRequestList()
            _ = await first.value
            await fresh.value

            let snapshot = await sdk.snapshot()
            XCTAssertEqual(snapshot.paymentRequestListCallCount, 1, invalidation)
            XCTAssertTrue(manager.pendingRequests.isEmpty, invalidation)
        }
    }

    func testReceivedPaymentContactsIncludeSharedServerRequestsAndLatePayments() throws {
        let payer = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        var record = try receivedPaymentRecord(counterparty: payer)
        record.proposalAppId = "paykit-server"
        record.state = .canceled
        let contacts = PaykitReceivedPaymentContacts(records: [record], network: .regtest)

        XCTAssertEqual(contacts.contact(onchainAddresses: ["bcrt1qfn50lqawrce0evh66qrnlt8j447lwmeyqp5gmd"]), payer)
        XCTAssertNil(contacts.contact(onchainAddresses: ["bcrt1qnewlist"]))
    }

    func testReceivedPaymentContactsRejectUnusableRequests() throws {
        let valid = try receivedPaymentRecord()
        var payer = valid
        payer.localRole = .payer
        var invalid = valid
        invalid.state = .invalidConflict
        var invalidReason = valid
        invalidReason.invalidReason = "conflicting terms"
        var unknownRole = valid
        unknownRole.localRole = nil
        var noTerms = valid
        noTerms.terms = nil
        var malformed = valid
        malformed.terms?.paymentEndpoints = ["btc-regtest-p2wpkh": "not JSON"]
        var wrongAsset = valid
        wrongAsset.terms?.amount.asset = "usd"
        var wrongNetwork = valid
        wrongNetwork.terms?.acceptedPaymentEndpointIdentifiers = ["btc-bitcoin-p2wpkh"]
        wrongNetwork.terms?.paymentEndpoints = ["btc-bitcoin-p2wpkh": #"{"value":"bcrt1qfn50lqawrce0evh66qrnlt8j447lwmeyqp5gmd"}"#]
        var badKey = valid
        badKey.counterparty = "invalid"
        var unaccepted = valid
        unaccepted.terms?.acceptedPaymentEndpointIdentifiers = []

        let contacts = PaykitReceivedPaymentContacts(
            records: [payer, invalid, invalidReason, unknownRole, noTerms, malformed, wrongAsset, wrongNetwork, badKey, unaccepted],
            network: .regtest
        )
        XCTAssertTrue(contacts.isEmpty)
    }

    func testReceivedPaymentContactsRejectAmbiguousAddressesAndTransactions() throws {
        let first = try receivedPaymentRecord()
        var sameContact = first
        sameContact.counterparty = String(first.counterparty.dropFirst(5))
        var other = try receivedPaymentRecord(counterparty: "pubky7don8zi885feihpjsyx7t53srod6z1n4xjiyaaxucpqarm6sh85o")
        let repeated = PaykitReceivedPaymentContacts(records: [first, sameContact], network: .regtest)
        XCTAssertEqual(repeated.contact(onchainAddresses: ["bcrt1qfn50lqawrce0evh66qrnlt8j447lwmeyqp5gmd"]), first.counterparty)
        let reused = PaykitReceivedPaymentContacts(records: [first, other], network: .regtest)
        XCTAssertNil(reused.contact(onchainAddresses: ["bcrt1qfn50lqawrce0evh66qrnlt8j447lwmeyqp5gmd"]))

        other.terms?.paymentEndpoints = ["btc-regtest-p2wpkh": #"{"value":"bcrt1qpsps9chsjnnd3veems9phzlvw42em682rsj8hh"}"#]
        let batched = PaykitReceivedPaymentContacts(records: [first, other], network: .regtest)
        XCTAssertNil(batched.contact(onchainAddresses: [
            "bcrt1qfn50lqawrce0evh66qrnlt8j447lwmeyqp5gmd",
            "bcrt1qpsps9chsjnnd3veems9phzlvw42em682rsj8hh",
        ]))
    }

    func testReceivedPaymentContactsMatchExactLightningInvoiceOnCorrectNetwork() throws {
        let invoice = "lnbcrt200n1p5hn4c8dqqnp4qwrgh4a03djj2sl34465uwnxhva0gtpjm4u8kvzgc5jergrkm9syypp55lwcgfpkdwuknmekjgte" +
            "d72n0ddl5qtaha7knk7c9n7yrjr4auassp5jgqw0a9w33e2ta4j7gyjrvsvu0lv844w895305nd8spnknq3f2hq9qyysgqcqzp2x" +
            "qyz5vqrzjq29gjy9sqjrrp48tz7hj2e5vm4l2dukc4csf2mn6qm32u3hted5leapyqqqqqqqtcsqqqqlgqqqqqqgq2qd2gk64eg2" +
            "kfxtdaryrlh98hvu97jdaxz2ma7aeyuy2uy9vkn9x5qft47p9taju297xnrehva20xcfml7wacuv737xv3xjjzyrtplcxqpfpu9dt"
        var record = try receivedPaymentRecord()
        record.terms?.acceptedPaymentEndpointIdentifiers = ["btc-lightning-bolt11"]
        record.terms?.paymentEndpoints = try ["btc-lightning-bolt11": PublicPaykitService.serializePayload(value: invoice)]
        let contacts = PaykitReceivedPaymentContacts(records: [record], network: .regtest)
        let paymentHash = try Bolt11Invoice.fromStr(invoiceStr: invoice).paymentHash()
        XCTAssertEqual(contacts.contact(paymentHash: paymentHash.uppercased()), record.counterparty)
        XCTAssertNil(contacts.contact(paymentHash: String(repeating: "0", count: 64)))
        let payment = LightningActivity(
            walletId: WalletScope.default, id: paymentHash, txType: .received, status: .succeeded,
            value: 20, fee: nil, invoice: "No invoice", message: "", timestamp: 123, preimage: nil,
            contact: nil, createdAt: nil, updatedAt: nil, seenAt: nil
        )
        guard case let .lightning(updated) = contacts.attributing(.lightning(payment)) else {
            return XCTFail("Expected contact from the exact payment hash")
        }
        XCTAssertEqual(updated.contact, record.counterparty)
        XCTAssertTrue(PaykitReceivedPaymentContacts(records: [record], network: .bitcoin).isEmpty)
        record.terms?.paymentEndpoints = ["btc-lightning-bolt11": #"{"value":"lnbcrt1invalid"}"#]
        XCTAssertTrue(PaykitReceivedPaymentContacts(records: [record], network: .regtest).isEmpty)
    }

    func testReceivedPaymentContactsUseEndpointNetworkForSignetAddresses() throws {
        let address = "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"
        var record = try receivedPaymentRecord()
        record.terms?.acceptedPaymentEndpointIdentifiers = ["btc-signet-p2wpkh"]
        record.terms?.paymentEndpoints = try ["btc-signet-p2wpkh": PublicPaykitService.serializePayload(value: address)]
        XCTAssertEqual(
            PaykitReceivedPaymentContacts(records: [record], network: .signet).contact(onchainAddresses: [address]), record.counterparty
        )
        XCTAssertTrue(PaykitReceivedPaymentContacts(records: [record], network: .bitcoin).isEmpty)
        XCTAssertTrue(PaykitReceivedPaymentContacts(records: [record], network: .testnet).isEmpty)
    }

    func testReceivedPaymentAttributionPreservesExistingContactsAndMetadata() throws {
        let record = try receivedPaymentRecord()
        let contacts = PaykitReceivedPaymentContacts(records: [record], network: .regtest)
        var payment = receivedOnchainActivity()
        XCTAssertNil(contacts.attributing(.onchain(payment)), "Wait for complete transaction outputs")
        guard case let .onchain(updated) = contacts.attributing(.onchain(payment), outputAddresses: [payment.address]) else {
            return XCTFail("Expected received contact attribution")
        }
        XCTAssertEqual(updated.contact, record.counterparty)
        XCTAssertEqual(updated.value, payment.value)
        XCTAssertEqual(updated.seenAt, payment.seenAt)
        XCTAssertEqual(updated.confirmTimestamp, payment.confirmTimestamp)
        payment.contact = "already assigned"
        XCTAssertNil(contacts.attributing(.onchain(payment), outputAddresses: [payment.address]))
        payment.contact = nil
        payment.txType = .sent
        XCTAssertNil(contacts.attributing(.onchain(payment), outputAddresses: [payment.address]))
    }

    func testReceivedPaymentAttributionRequiresReceivingAddressInRequestAndOutputs() throws {
        let contacts = try PaykitReceivedPaymentContacts(records: [receivedPaymentRecord()], network: .regtest)
        var payment = receivedOnchainActivity()
        let requestAddress = payment.address
        let otherAddress = "bcrt1qpsps9chsjnnd3veems9phzlvw42em682rsj8hh"
        XCTAssertNil(contacts.attributing(.onchain(payment), outputAddresses: [otherAddress]))
        payment.address = otherAddress
        XCTAssertNil(contacts.attributing(.onchain(payment), outputAddresses: [otherAddress, requestAddress]))
    }

    func testReceivedPaymentAttributionKeepsAmbiguityVetoAcrossOutputs() throws {
        let payment = receivedOnchainActivity()
        var other = try receivedPaymentRecord(counterparty: "pubky7don8zi885feihpjsyx7t53srod6z1n4xjiyaaxucpqarm6sh85o")
        let otherAddress = "bcrt1qpsps9chsjnnd3veems9phzlvw42em682rsj8hh"
        other.terms?.paymentEndpoints = try ["btc-regtest-p2wpkh": PublicPaykitService.serializePayload(value: otherAddress)]
        let contacts = try PaykitReceivedPaymentContacts(records: [receivedPaymentRecord(), other], network: .regtest)
        XCTAssertNil(contacts.attributing(.onchain(payment), outputAddresses: [payment.address, otherAddress]))
    }

    func testReceivedPaymentAttributionMatchesLateServerInvoiceAfterChangeOutput() throws {
        var record = try receivedPaymentRecord()
        record.proposalAppId = "paykit-server"
        record.state = .canceled
        let payment = receivedOnchainActivity()
        let contacts = PaykitReceivedPaymentContacts(records: [record], network: .regtest)
        guard case let .onchain(updated) = contacts.attributing(
            .onchain(payment), outputAddresses: ["bcrt1qpsps9chsjnnd3veems9phzlvw42em682rsj8hh", payment.address]
        ) else { return XCTFail("Expected the receiving server invoice to identify its contact") }
        XCTAssertEqual(updated.contact, record.counterparty)
    }

    private func receivedOnchainActivity() -> OnchainActivity {
        OnchainActivity(
            walletId: WalletScope.default, id: "received", txType: .received, txId: "tx", value: 15000,
            fee: 0, feeRate: 0, address: "bcrt1qfn50lqawrce0evh66qrnlt8j447lwmeyqp5gmd", confirmed: true, timestamp: 123,
            isBoosted: false, boostTxIds: [], isTransfer: false, doesExist: true, confirmTimestamp: 124,
            channelId: nil, transferTxId: nil, contact: nil, createdAt: 123, updatedAt: 124, seenAt: 125
        )
    }

    func testReceivedPaymentContactsRefreshAndClearWithIdentity() async throws {
        var record = try receivedPaymentRecord()
        record.proposalAppId = "paykit-server"
        let sdk = PaymentRequestSdkMock(records: [])
        let manager = paymentRequestManager(sdk: sdk)
        manager.activate(identity: "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg")
        await manager.refresh()
        XCTAssertTrue(manager.receivedPaymentContacts.isEmpty)
        await sdk.setRecords([record])
        let visibleRequests = await sdk.paymentRequests()
        XCTAssertTrue(visibleRequests.isEmpty)
        await manager.refresh()
        XCTAssertEqual(
            manager.receivedPaymentContacts.contact(onchainAddresses: ["bcrt1qfn50lqawrce0evh66qrnlt8j447lwmeyqp5gmd"]),
            record.counterparty
        )
        XCTAssertTrue(manager.historyRequests.isEmpty)
        manager.activate(identity: "pubky7don8zi885feihpjsyx7t53srod6z1n4xjiyaaxucpqarm6sh85o")
        XCTAssertTrue(manager.receivedPaymentContacts.isEmpty)
    }

    private func receivedPaymentRecord(
        counterparty: String = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
    ) throws -> PaymentRequestRecord {
        try paymentRequestRecord(
            counterparty: counterparty, role: .payee,
            endpoints: ["btc-regtest-p2wpkh"], paymentEndpoints: ["btc-regtest-p2wpkh": #"{"value":"bcrt1qfn50lqawrce0evh66qrnlt8j447lwmeyqp5gmd"}"#]
        )
    }

    func testRequestEndpointsKeepSeparateAddressesWithoutChangingContactListState() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.removeObject(forKey: PrivatePaykitService.cacheStateKey)
        let service = PrivatePaykitService()
        let publicKey = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let method = PublicPaykitService.onchainMethodId(for: "bcrt1qinvoice")
        let addresses = ["invoice-a": "bcrt1qinvoicea", "invoice-b": "bcrt1qinvoiceb"]
        try await service.consumePrivatePaymentList(
            publicKey: publicKey,
            context: PrivatePaykitPaymentContext(paymentAppsByEndpoint: [:], paymentListVersion: 7),
            attemptId: UUID()
        )

        for (index, id) in ["invoice-a", "invoice-b", "invoice-a"].enumerated() {
            let address = try XCTUnwrap(addresses[id])
            let endpointData = try PublicPaykitService.serializePayload(value: address)
            let record = try paymentRequestRecord(
                id: id,
                counterparty: publicKey,
                endpoints: [method.rawValue],
                paymentEndpoints: [method.rawValue: endpointData]
            )
            let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
            let latest = try PublicPaykitService.Endpoint(
                methodId: method,
                value: "current-list-target-\(index)",
                min: nil,
                max: nil,
                rawPayload: PublicPaykitService.serializePayload(value: "current-list-target-\(index)")
            )
            await service.cacheResolvedEndpoints([latest], publicKey: publicKey)
            let resolution = try boundResolution(publicKey: publicKey, method: method, payload: endpointData)
            let result = await service.privatePaymentResult(
                publicKey: publicKey,
                paymentRequest: request,
                resolution: resolution,
                validateEndpoints: { endpoints, allowUsedOnchainAddress in
                    XCTAssertFalse(allowUsedOnchainAddress)
                    XCTAssertEqual(endpoints.map(\.value), [address])
                    return endpoints
                }
            )
            guard case let .opened(target, context) = result else { return XCTFail("Expected the bound invoice") }
            XCTAssertEqual(target, address)
            let paymentContext = try XCTUnwrap(context)
            XCTAssertNil(paymentContext.paymentListVersion)
            XCTAssertEqual(try paymentContext.paymentAppId(for: method.rawValue), "bitkit")
            try await service.consumePrivatePaymentList(publicKey: publicKey, context: paymentContext, attemptId: UUID())
            let contact = await service.state.contacts[publicKey]
            XCTAssertEqual(contact?.consumedPrivatePaymentListVersion, 7)
            XCTAssertEqual(contact?.cachedResolvedEndpoints.map(\.endpointData), [latest.rawPayload])
        }
    }

    func testRequestEndpointUsesOnlyPayableResolvedCandidates() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.removeObject(forKey: PrivatePaykitService.cacheStateKey)
        let service = PrivatePaykitService()
        let method = PublicPaykitService.onchainMethodId(for: "bcrt1qinvoice")
        let payload = try PublicPaykitService.serializePayload(value: "bcrt1qinvoice")
        let record = try paymentRequestRecord(endpoints: [method.rawValue], paymentEndpoints: [method.rawValue: payload])
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        var resolution = try boundResolution(publicKey: request.counterparty, method: method, payload: payload)
        let rejected = await service.privatePaymentResult(
            publicKey: request.counterparty,
            paymentRequest: request,
            resolution: resolution,
            validateEndpoints: { _, _ in [] }
        )
        guard case .notOpened = rejected else { return XCTFail("Wallet validation must reject the target") }
        let generic = await service.privatePaymentResult(
            publicKey: request.counterparty,
            paymentRequest: nil,
            resolution: resolution,
            validateEndpoints: { endpoints, _ in endpoints }
        )
        guard case .notOpened = generic else { return XCTFail("Contact payments require a list version") }
        resolution.payableEndpoints = []
        let missing = await service.privatePaymentResult(
            publicKey: request.counterparty,
            paymentRequest: request,
            resolution: resolution,
            validateEndpoints: { endpoints, _ in endpoints }
        )
        guard case .noEndpoint = missing else { return XCTFail("Missing bound endpoints must not fall back") }
    }

    func testUsedOnchainAddressIsPayableOnlyForBoundRecurringRequest() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.removeObject(forKey: PrivatePaykitService.cacheStateKey)
        let service = PrivatePaykitService()
        let address = "bcrt1qfn50lqawrce0evh66qrnlt8j447lwmeyqp5gmd"
        let method = PublicPaykitService.MethodId.regtestOnchainP2wpkh
        let payload = try PublicPaykitService.serializePayload(value: address)
        let now = try XCTUnwrap(PaykitPaymentRequest.parseDate("2027-01-15T08:00:00Z"))
        let record = try paymentRequestRecord(
            counterparty: "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg",
            state: .activeRecurring,
            recurrence: PaymentRequestRecurrence(
                every: 1, unit: "month", startsAt: "2027-01-01T08:00:00Z", anchor: "2027-01-01T08:00:00Z", endsAt: nil
            ),
            endpoints: [method.rawValue],
            paymentEndpoints: [method.rawValue: payload]
        )
        let subscription = try XCTUnwrap(PaykitSubscription(record: record))
        let recurring = try XCTUnwrap(subscription.requests(through: now, acceptedAt: PaykitPreciseInstant(date: now)).first)
        let oneTime = try XCTUnwrap(PaykitPaymentRequest(record: paymentRequestRecord(
            counterparty: record.counterparty, endpoints: [method.rawValue], paymentEndpoints: [method.rawValue: payload]
        ), now: now))
        let cases: [(request: PaykitPaymentRequest?, version: UInt64?, opens: Bool)] = [
            (recurring, nil, true),
            (recurring, 7, false),
            (oneTime, nil, false),
            (oneTime, 7, false),
            (nil, 7, false),
        ]

        for testCase in cases {
            var resolution = try boundResolution(publicKey: record.counterparty, method: method, payload: payload)
            resolution.privatePaymentListVersion = testCase.version
            var usageChecks = 0
            let result = await service.privatePaymentResult(
                publicKey: record.counterparty,
                paymentRequest: testCase.request,
                resolution: resolution,
                validateEndpoints: { endpoints, allowUsedOnchainAddress in
                    XCTAssertEqual(allowUsedOnchainAddress, testCase.opens)
                    return await service.privatePayableEndpoints(
                        from: endpoints,
                        publicKey: record.counterparty,
                        allowUsedOnchainAddress: allowUsedOnchainAddress,
                        isAddressUsed: {
                            XCTAssertEqual($0, address)
                            usageChecks += 1
                            return true
                        }
                    )
                }
            )
            XCTAssertEqual(usageChecks, testCase.opens ? 0 : 1)
            if testCase.opens {
                guard case let .opened(target, context) = result else { return XCTFail("Expected the recurring fixed address") }
                XCTAssertEqual(target, address)
                XCTAssertNil(try XCTUnwrap(context).paymentListVersion)
            } else {
                guard case .notOpened = result else { return XCTFail("Used list and one-time addresses must remain unavailable") }
            }
        }
    }

    func testRequestEndpointCannotBypassExecutionClaimRejection() async throws {
        let method = PublicPaykitService.onchainMethodId(for: "bcrt1qinvoice")
        var record = try paymentRequestRecord(
            endpoints: [method.rawValue],
            paymentEndpoints: [method.rawValue: PublicPaykitService.serializePayload(value: "bcrt1qinvoice")]
        )
        let sdk = PaymentRequestSdkMock(records: [record])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        record.executionClaimAppId = "other-app"
        await sdk.setRecords([record])
        var consumed = false

        do {
            try await manager.prepareForPayment(request) { consumed = true }
            XCTFail("Expected execution claim rejection")
        } catch {
            XCTAssertEqual(error as? PaymentRequestSdkMockError, .requestMissing)
        }

        XCTAssertFalse(consumed)
        XCTAssertFalse(manager.isApprovedForPayment(request))
        let snapshot = await sdk.snapshot()
        XCTAssertTrue(snapshot.acceptedRequests.isEmpty)
    }

    func testReleasedRequestCanBeHandledWithoutTakingAnotherAppsClaim() throws {
        var record = try paymentRequestRecord()
        record.payerAppId = "other-app"
        for state in [Paykit.PaymentRequestLifecycleState.accepted, .activeRecurring] {
            record.state = state
            record.executionClaimAppId = nil
            XCTAssertTrue(PaykitSdkService.isBitkitPaymentRequest(record))
            record.executionClaimAppId = "other-app"
            XCTAssertFalse(PaykitSdkService.isBitkitPaymentRequest(record))
            record.executionClaimAppId = "bitkit"
            XCTAssertTrue(PaykitSdkService.isBitkitPaymentRequest(record))
        }
        record.executionClaimAppId = nil
        record.state = .rejected
        XCTAssertFalse(PaykitSdkService.isBitkitPaymentRequest(record))
        record.payerAppId = "bitkit"
        XCTAssertTrue(PaykitSdkService.isBitkitPaymentRequest(record))
    }

    private func boundResolution(
        publicKey: String,
        method: PublicPaykitService.MethodId,
        payload: String
    ) throws -> PrivateContactPaymentResolution {
        let payload = PaymentPayload(text: payload)
        return PrivateContactPaymentResolution(
            status: .payable,
            state: .available,
            privatePaymentListVersion: nil,
            payableEndpoints: [ResolvedPrivatePaymentEndpoint(
                counterparty: publicKey,
                appId: "bitkit",
                identifier: method.rawValue,
                payload: payload,
                target: PaymentTarget(payload: payload)
            )]
        )
    }

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
        let request = try XCTUnwrap(
            subscription.requests(through: through, acceptedAt: PaykitPreciseInstant(date: acceptedAt)).first
        )

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
                acceptedAt: [subscription.id: PaykitPreciseInstant(date: now)],
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
            acceptedAt: [subscription.id: PaykitPreciseInstant(date: now)],
            pendingRequestIds: [request.id],
            payerIdentity: payerIdentity,
            notificationsEnabled: false,
            now: now
        )

        let pendingIdentifiers = await center.pendingIdentifiers
        XCTAssertTrue(pendingIdentifiers.isEmpty)
    }

    func testClockOffsetReschedulesPendingSubscriptionNotification() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:30Z"))
        let subscription = try weeklySubscription()
        let payerIdentity = "pubky\(String(repeating: "z", count: 52))"
        let acceptedAt = [subscription.id: PaykitPreciseInstant(date: now)]
        let nextPeriod = try XCTUnwrap(subscription.recurrence.upcomingPeriods(after: now, limit: 1).first)
        let identifier = PaykitSubscriptionNotificationIdentifier.identifier(
            identity: payerIdentity,
            subscription: subscription,
            period: nextPeriod
        )
        let center = PaykitSubscriptionNotificationCenterMock()
        let scheduler = PaykitSubscriptionNotificationScheduler(center: center)

        await scheduler.synchronize(
            [subscription],
            acceptedAt: acceptedAt,
            pendingRequestIds: [],
            payerIdentity: payerIdentity,
            notificationsEnabled: true,
            now: now
        )
        var triggers = try await center.calendarTriggers()
        XCTAssertEqual(triggers[identifier]?.day, 22)

        let offset: TimeInterval = 3 * 24 * 60 * 60
        await scheduler.synchronize(
            [subscription],
            acceptedAt: acceptedAt,
            pendingRequestIds: [],
            payerIdentity: payerIdentity,
            notificationsEnabled: true,
            now: now.addingTimeInterval(offset),
            clockOffset: offset
        )
        triggers = try await center.calendarTriggers()
        XCTAssertEqual(triggers[identifier]?.day, 19)
        XCTAssertEqual(triggers[identifier]?.hour, 8)
    }

    func testClockOffsetNotifiesPeriodThatBecomesDueFromTheJump() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:30Z"))
        let subscription = try weeklySubscription()
        let payerIdentity = "pubky\(String(repeating: "z", count: 52))"
        let acceptedAt = [subscription.id: PaykitPreciseInstant(date: now)]
        let center = PaykitSubscriptionNotificationCenterMock()
        let scheduler = PaykitSubscriptionNotificationScheduler(center: center)
        await scheduler.synchronize(
            [subscription],
            acceptedAt: acceptedAt,
            pendingRequestIds: [],
            payerIdentity: payerIdentity,
            notificationsEnabled: true,
            now: now
        )

        let offset: TimeInterval = 10 * 24 * 60 * 60
        let shiftedNow = now.addingTimeInterval(offset)
        let dueRequests = try subscription.requests(through: shiftedNow, acceptedAt: XCTUnwrap(acceptedAt[subscription.id]))
        let jumpedRequest = try XCTUnwrap(dueRequests.first { $0.billingPeriod?.sdkValue.startsAt == "2027-01-22T08:00:00Z" })
        await scheduler.synchronize(
            [subscription],
            acceptedAt: acceptedAt,
            pendingRequestIds: Set(dueRequests.map(\.id)),
            payerIdentity: payerIdentity,
            notificationsEnabled: true,
            now: shiftedNow,
            clockOffset: offset
        )

        let identifier = try XCTUnwrap(
            PaykitSubscriptionNotificationIdentifier.identifier(identity: payerIdentity, requestId: jumpedRequest.id)
        )
        let triggers = try await center.calendarTriggers()
        let jumped = try XCTUnwrap(triggers[identifier])
        XCTAssertEqual(jumped.day, 15)
        XCTAssertEqual(jumped.second, 32)
    }

    func testClockOffsetNotifiesOnePeriodPerSubscriptionAndStaysWithinTheNotificationCap() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:30Z"))
        let subscription = try weeklySubscription(unit: "day")
        let payerIdentity = "pubky\(String(repeating: "z", count: 52))"
        let acceptedAt = [subscription.id: PaykitPreciseInstant(date: now)]
        let center = PaykitSubscriptionNotificationCenterMock()
        let scheduler = PaykitSubscriptionNotificationScheduler(center: center)
        await scheduler.synchronize(
            [subscription],
            acceptedAt: acceptedAt,
            pendingRequestIds: [],
            payerIdentity: payerIdentity,
            notificationsEnabled: true,
            now: now
        )

        let offset: TimeInterval = 365 * 24 * 60 * 60
        let shiftedNow = now.addingTimeInterval(offset)
        let dueRequests = try subscription.requests(through: shiftedNow, acceptedAt: XCTUnwrap(acceptedAt[subscription.id]))
        XCTAssertGreaterThan(dueRequests.count, 300)
        await scheduler.synchronize(
            [subscription],
            acceptedAt: acceptedAt,
            pendingRequestIds: Set(dueRequests.map(\.id)),
            payerIdentity: payerIdentity,
            notificationsEnabled: true,
            now: shiftedNow,
            clockOffset: offset
        )

        let triggers = try await center.calendarTriggers()
        XCTAssertEqual(triggers.values.filter { $0.day == 15 && $0.second == 32 }.count, 1)
        XCTAssertLessThanOrEqual(triggers.count, 32)
    }

    func testClockOffsetCatchUpAlertsServeEverySubscriptionBeforeTheCap() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:30Z"))
        let busy = try weeklySubscription(id: "busy", unit: "day")
        let quiet = try weeklySubscription(id: "quiet", endsAt: "2027-01-29T08:00:00Z")
        let subscriptions = [busy, quiet]
        let payerIdentity = "pubky\(String(repeating: "z", count: 52))"
        let acceptedAt = Dictionary(uniqueKeysWithValues: subscriptions.map { ($0.id, PaykitPreciseInstant(date: now)) })
        let center = PaykitSubscriptionNotificationCenterMock()
        let scheduler = PaykitSubscriptionNotificationScheduler(center: center)
        await scheduler.synchronize(
            subscriptions,
            acceptedAt: acceptedAt,
            pendingRequestIds: [],
            payerIdentity: payerIdentity,
            notificationsEnabled: true,
            now: now
        )

        let offset: TimeInterval = 60 * 24 * 60 * 60
        let shiftedNow = now.addingTimeInterval(offset)
        let dueIds = Set(subscriptions.flatMap { $0.requests(through: shiftedNow, acceptedAt: acceptedAt[$0.id]!).map(\.id) })
        await scheduler.synchronize(
            subscriptions,
            acceptedAt: acceptedAt,
            pendingRequestIds: dueIds,
            payerIdentity: payerIdentity,
            notificationsEnabled: true,
            now: shiftedNow,
            clockOffset: offset
        )

        let catchUpIdentifiers = try await center.calendarTriggers().filter { $0.value.day == 15 && $0.value.second == 32 }.keys
        XCTAssertEqual(catchUpIdentifiers.count, 2)
        XCTAssertTrue(catchUpIdentifiers.contains { $0.contains("|busy|") })
        XCTAssertTrue(catchUpIdentifiers.contains { $0.contains("|quiet|") })
    }

    func testClockOffsetNotifiesPeriodDueAfterTheJumpCrossesTheSubscriptionEnd() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:30Z"))
        let subscription = try weeklySubscription(endsAt: "2027-01-29T08:00:00Z")
        let payerIdentity = "pubky\(String(repeating: "z", count: 52))"
        let acceptedAt = [subscription.id: PaykitPreciseInstant(date: now)]
        let center = PaykitSubscriptionNotificationCenterMock()
        let scheduler = PaykitSubscriptionNotificationScheduler(center: center)
        await scheduler.synchronize(
            [subscription],
            acceptedAt: acceptedAt,
            pendingRequestIds: [],
            payerIdentity: payerIdentity,
            notificationsEnabled: true,
            now: now
        )

        let offset: TimeInterval = 20 * 24 * 60 * 60
        let shiftedNow = now.addingTimeInterval(offset)
        let dueRequests = try subscription.requests(through: shiftedNow, acceptedAt: XCTUnwrap(acceptedAt[subscription.id]))
        XCTAssertFalse(subscription.isActive(at: shiftedNow))
        await scheduler.synchronize(
            [subscription],
            acceptedAt: acceptedAt,
            pendingRequestIds: Set(dueRequests.map(\.id)),
            payerIdentity: payerIdentity,
            notificationsEnabled: true,
            now: shiftedNow,
            clockOffset: offset
        )

        let triggers = try await center.calendarTriggers()
        XCTAssertEqual(triggers.values.filter { $0.day == 15 && $0.second == 32 }.count, 1)
    }

    func testSupersededSynchronizationDoesNotConsumeTheClockJump() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:30Z"))
        let subscription = try weeklySubscription()
        let payerIdentity = "pubky\(String(repeating: "z", count: 52))"
        let acceptedAt = [subscription.id: PaykitPreciseInstant(date: now)]
        let center = PaykitSubscriptionNotificationCenterMock()
        let scheduler = PaykitSubscriptionNotificationScheduler(center: center)
        await scheduler.synchronize(
            [subscription],
            acceptedAt: acceptedAt,
            pendingRequestIds: [],
            payerIdentity: payerIdentity,
            notificationsEnabled: true,
            now: now
        )

        let offset: TimeInterval = 10 * 24 * 60 * 60
        let shiftedNow = now.addingTimeInterval(offset)
        let dueIds = try Set(subscription.requests(through: shiftedNow, acceptedAt: XCTUnwrap(acceptedAt[subscription.id])).map(\.id))
        await center.pauseNextPendingRequests()
        let first = Task {
            await scheduler.synchronize(
                [subscription],
                acceptedAt: acceptedAt,
                pendingRequestIds: dueIds,
                payerIdentity: payerIdentity,
                notificationsEnabled: true,
                now: shiftedNow,
                clockOffset: offset
            )
        }
        try await waitUntil { await center.isPendingRequestsPaused }
        await scheduler.synchronize(
            [subscription],
            acceptedAt: acceptedAt,
            pendingRequestIds: dueIds,
            payerIdentity: payerIdentity,
            notificationsEnabled: true,
            now: shiftedNow,
            clockOffset: offset
        )
        await center.resumePendingRequests()
        await first.value

        let triggers = try await center.calendarTriggers()
        XCTAssertEqual(triggers.values.filter { $0.day == 15 && $0.second == 32 }.count, 1)
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

    func testBlockingPeerHidesRequestsFromAnEarlierSnapshot() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let record = try paymentRequestRecord(
            counterparty: "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xy",
            expiresAt: timestamp(now.addingTimeInterval(60))
        )
        let sdk = PaymentRequestSdkMock(records: [record])
        let manager = paymentRequestManager(sdk: sdk, clock: PaymentRequestTestClock(now))
        await manager.refresh()
        XCTAssertEqual(manager.pendingRequests.count, 1)
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: record.counterparty, state: .blocked)],
            requestCapabilitiesByPublicKey: [:]
        )
        await manager.refresh()
        XCTAssertTrue(manager.pendingRequests.isEmpty)
        await sdk.setRecords([])
        await manager.refresh()
        XCTAssertTrue(manager.historyRequests.isEmpty)
    }

    func testBlockedPeerHidesACanceledSubscriptionStillPaidThrough() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let period = BillingPeriod(startsAt: "2027-01-01T08:00:00Z", endsAt: "2027-02-01T08:00:00Z")
        let record = try paymentRequestRecord(
            counterparty: "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xy",
            state: .canceled,
            recurrence: PaymentRequestRecurrence(
                every: 1,
                unit: "month",
                startsAt: period.startsAt,
                anchor: period.startsAt,
                endsAt: nil
            ),
            paymentProofs: [paymentProofRecord(
                endpoint: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                kind: .lightning,
                billingPeriod: period
            )]
        )
        let sdk = PaymentRequestSdkMock(records: [record])
        let manager = paymentRequestManager(sdk: sdk, clock: PaymentRequestTestClock(now))
        await manager.refresh()
        let subscription = try XCTUnwrap(manager.subscriptions.first)
        XCTAssertTrue(subscription.runsUntilPaidThrough(at: now))

        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: record.counterparty, state: .blocked)],
            requestCapabilitiesByPublicKey: [:]
        )
        await manager.refresh()
        XCTAssertTrue(manager.subscriptions.isEmpty)
        let sections = subscriptionSections(subscriptions: manager.subscriptions, now: now)
        XCTAssertTrue(sections.active.isEmpty && sections.created.isEmpty && sections.expired.isEmpty)
        XCTAssertEqual(subscriptionMonthlyCostSats(subscriptions: manager.subscriptions, now: now), 0)
    }

    func testBlockingAnAlreadyPresentedAcceptedRequestPreventsPayment() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let record = try paymentRequestRecord(
            counterparty: "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xy",
            state: .accepted
        )
        let sdk = PaymentRequestSdkMock(records: [record])
        let manager = paymentRequestManager(sdk: sdk, clock: PaymentRequestTestClock(now), acceptedRecords: [record])
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: record.counterparty, state: .blocked)],
            requestCapabilitiesByPublicKey: [:]
        )
        var consumed = false
        do {
            try await manager.prepareForPayment(request) { consumed = true }
            XCTFail("Expected the deleted contact's request to be unavailable")
        } catch {
            XCTAssertEqual(error as? PaykitPaymentRequestError, .requestUnavailable)
        }
        XCTAssertFalse(consumed)
        XCTAssertFalse(manager.isApprovedForPayment(request))
    }

    func testApprovedPaymentRechecksBlockingInEachSoftwareSendRouteWithoutRepeatingAcceptance() async throws {
        let record = try paymentRequestRecord(counterparty: "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xy")
        let sdk = PaymentRequestSdkMock(records: [record])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        var consumedCount = 0
        try await manager.prepareForPayment(request) { consumedCount += 1 }
        try await manager.prepareForPayment(request) { consumedCount += 1 }
        XCTAssertEqual(consumedCount, 1)
        let accepted = await sdk.snapshot().acceptedRequests
        XCTAssertEqual(accepted.count, 1)
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: record.counterparty, state: .blocked)],
            requestCapabilitiesByPublicKey: [:]
        )
        var lightningSendCalls = 0
        var lnurlSendCalls = 0
        var onchainPreparationCalls = 0
        var onchainAuthorizationCalls = 0
        var onchainSendCalls = 0
        var authorizationFailureCalls = 0
        do {
            try await SendConfirmationView.sendLightningPayment(
                request: request,
                authorize: { try await manager.ensurePaymentAllowed($0) },
                onAuthorizationFailure: { _ in authorizationFailureCalls += 1 }
            ) {
                lightningSendCalls += 1
            }
            XCTFail("Expected the Lightning send to be rejected")
        } catch {
            XCTAssertEqual(error as? PaykitPaymentRequestError, .requestUnavailable)
        }
        do {
            try await LnurlPayConfirm.sendLightningPayment(
                request: request,
                authorize: { try await manager.ensurePaymentAllowed($0) },
                onAuthorizationFailure: { _ in authorizationFailureCalls += 1 }
            ) {
                lnurlSendCalls += 1
            }
            XCTFail("Expected the LNURL send to be rejected")
        } catch {
            XCTAssertEqual(error as? PaykitPaymentRequestError, .requestUnavailable)
        }
        do {
            try await SendConfirmationView.sendOnchainPayment(
                request: request,
                prepareBroadcast: { _ in onchainPreparationCalls += 1 },
                authorize: { try await manager.ensurePaymentAllowed($0) },
                onAuthorizationFailure: { _ in authorizationFailureCalls += 1 },
                onAuthorized: { _ in onchainAuthorizationCalls += 1 },
                send: { beforeBroadcastAttempt in
                    try await beforeBroadcastAttempt()
                    onchainSendCalls += 1
                }
            )
            XCTFail("Expected the on-chain send to be rejected")
        } catch {
            XCTAssertEqual(error as? PaykitPaymentRequestError, .requestUnavailable)
        }
        XCTAssertEqual(consumedCount, 1)
        XCTAssertEqual(lightningSendCalls, 0)
        XCTAssertEqual(lnurlSendCalls, 0)
        XCTAssertEqual(onchainPreparationCalls, 1)
        XCTAssertEqual(onchainAuthorizationCalls, 0)
        XCTAssertEqual(onchainSendCalls, 0)
        XCTAssertEqual(authorizationFailureCalls, 3)
        XCTAssertFalse(manager.isApprovedForPayment(request))
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

    func testRecoveryRequiredIncomingRequestUsesUnderlyingUnpaidLifecycle() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let proposal = try XCTUnwrap(PaykitPaymentRequest(
            record: paymentRequestRecord(state: .recoveryRequired),
            now: now
        ))
        let accepted = try XCTUnwrap(PaykitPaymentRequest(
            record: paymentRequestRecord(
                state: .recoveryRequired,
                expiresAt: timestamp(now.addingTimeInterval(-1)),
                acceptedEventId: "accepted"
            ),
            now: now
        ))

        XCTAssertEqual(proposal.lifecycleState, .proposed)
        XCTAssertTrue(proposal.requiresAcceptance)
        XCTAssertEqual(accepted.lifecycleState, .accepted)
        XCTAssertFalse(accepted.requiresAcceptance)
    }

    func testRecoveryRequiredIncomingRequestRejectsTerminalOrExpiredEvidence() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [(PaymentRequestRecord, PaykitPaymentRequest.ParseFailure)] = try [
            (
                paymentRequestRecord(state: .recoveryRequired, expiresAt: timestamp(now)),
                .expired
            ),
            (
                paymentRequestRecord(state: .recoveryRequired, rejectedEventId: "rejected"),
                .nonActionableState
            ),
            (
                paymentRequestRecord(state: .recoveryRequired, canceledEventId: "canceled"),
                .nonActionableState
            ),
            (
                paymentRequestRecord(
                    state: .recoveryRequired,
                    acceptedEventId: "accepted",
                    paymentProofs: [paymentProofRecord(
                        endpoint: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                        kind: .lightning
                    )]
                ),
                .nonActionableState
            ),
        ]

        for (record, expectedFailure) in cases {
            guard case let .failure(failure) = PaykitPaymentRequest.parseIncoming(record: record, now: now) else {
                XCTFail("Expected \(record.paymentRequestId) to fail parsing")
                continue
            }
            XCTAssertEqual(failure, expectedFailure)
        }
    }

    func testIncomingParseFailuresAreReasonSpecific() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [(PaymentRequestRecord, PaykitPaymentRequest.ParseFailure)] = try [
            (paymentRequestRecord(id: "missing-role", role: nil), .missingLocalRole),
            (paymentRequestRecord(id: "outgoing", role: .payee), .outgoingRequest),
            (paymentRequestRecord(id: "unknown-role", role: .unknown), .unsupportedLocalRole),
            (paymentRequestRecord(id: "missing-terms"), .missingTerms),
            (paymentRequestRecord(id: "wrong-asset", asset: "BTC"), .unsupportedAsset),
            (
                paymentRequestRecord(id: "payment-deadline", paymentDeadline: .periodStart(seconds: 3600)),
                .unsupportedPaymentDeadline
            ),
            (paymentRequestRecord(id: "invalid-deadline", paymentDeadline: .at(timestamp: "invalid")), .invalidPaymentDeadline),
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

    func testAbsolutePaymentDeadlineIsInclusiveAndIndependentOfProposalExpiry() throws {
        let now = try XCTUnwrap(PaykitPaymentRequest.parseDate("2027-01-15T08:00:00.500Z"))
        let cases: [(String, Bool)] = [
            ("2027-01-15T08:00:01Z", true),
            ("2027-01-15T08:00:00.500000001Z", true),
            ("2027-01-15T08:00:00.500Z", true),
            ("2027-01-15T08:00:00.499999999Z", false),
            ("2027-01-15T08:00:00Z", false),
            ("2027-01-15T08:00:01+00:00", false),
            ("not-a-timestamp", false),
        ]
        for (deadline, isTimely) in cases {
            for state in [PaymentRequestLifecycleState.proposed, .accepted] {
                let record = try paymentRequestRecord(
                    state: state,
                    expiresAt: timestamp(now.addingTimeInterval(state == .accepted ? -60 : 60)),
                    paymentDeadline: .at(timestamp: deadline)
                )
                let request = PaykitPaymentRequest(record: record, now: now)
                XCTAssertEqual(request != nil, isTimely, "\(state), \(deadline)")
                if let request {
                    XCTAssertFalse(request.isExpired(at: now))
                    XCTAssertEqual(request.paymentDeadline, PaykitPreciseInstant(timestamp: deadline))
                    XCTAssertEqual(request.updatingLifecycleState(.accepted).paymentDeadline, request.paymentDeadline)
                }
            }
        }
    }

    func testPaymentDeadlineCrossingDuringPreparationDoesNotApprovePayment() async throws {
        for stage in ["before", "consume", "accept"] {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let clock = PaymentRequestTestClock(now)
            let record = try paymentRequestRecord(paymentDeadline: .at(timestamp: timestamp(now.addingTimeInterval(1))))
            let sdk = PaymentRequestSdkMock(records: [record])
            let manager = paymentRequestManager(sdk: sdk, clock: clock)
            await manager.refresh()
            let request = try XCTUnwrap(manager.pendingRequests.first)
            if stage == "before" { clock.advance(by: 2) }
            if stage == "accept" { await sdk.pauseNextAccept() }

            let preparation = Task {
                try await manager.prepareForPayment(request) {
                    if stage == "consume" { clock.advance(by: 2) }
                }
            }
            if stage == "accept" {
                try await waitUntil { await sdk.acceptIsPaused() }
                clock.advance(by: 2)
                await sdk.resumeAccept()
            }
            do {
                try await preparation.value
                XCTFail("Expired preparation must not approve payment: \(stage)")
            } catch {
                XCTAssertEqual(error as? PaykitPaymentRequestError, .requestExpired, stage)
            }
            XCTAssertFalse(manager.isApprovedForPayment(request), stage)
            let accepted = await sdk.snapshot().acceptedRequests
            XCTAssertEqual(accepted.count, stage == "accept" ? 1 : 0, stage)
        }
    }

    func testPaymentDeadlineIsRecheckedAfterAuthorizationInEverySoftwareSendRoute() async throws {
        for route in ["lightning", "lnurl", "onchain"] {
            for expiryStage in ["timely", "preparation", "authorization"] {
                let crossesDeadline = expiryStage != "timely"
                let now = Date(timeIntervalSince1970: 1_800_000_000)
                let clock = PaymentRequestTestClock(now)
                let record = try paymentRequestRecord(
                    expiresAt: timestamp(now.addingTimeInterval(1)),
                    paymentDeadline: .at(timestamp: timestamp(now.addingTimeInterval(10)))
                )
                let sdk = PaymentRequestSdkMock(records: [record])
                let manager = paymentRequestManager(sdk: sdk, clock: clock)
                await manager.refresh()
                let request = try XCTUnwrap(manager.pendingRequests.first)
                try await manager.prepareForPayment(request)
                clock.advance(by: 10)
                XCTAssertTrue(manager.isApprovedForPayment(request), "Acceptance survives proposal expiry")
                // Fee calculation, PIN confirmation and LNURL retrieval all finish before this authorization.
                if expiryStage == "preparation" { clock.advance(by: 0.001) }
                else { await sdk.pauseNextLinkedPeers() }

                var sent = false
                var authorizationFailed = false
                let authorize: (PaykitPaymentRequest) async throws -> Void = { try await manager.ensurePaymentAllowed($0) }
                let onFailure: (Error) async -> Void = { _ in authorizationFailed = true }
                let execution = Task {
                    switch route {
                    case "lightning":
                        try await SendConfirmationView.sendLightningPayment(
                            request: request, authorize: authorize, onAuthorizationFailure: onFailure
                        ) { sent = true }
                    case "lnurl":
                        try await LnurlPayConfirm.sendLightningPayment(
                            request: request, authorize: authorize, onAuthorizationFailure: onFailure
                        ) { sent = true }
                    default:
                        try await SendConfirmationView.sendOnchainPayment(
                            request: request, prepareBroadcast: { _ in }, authorize: authorize,
                            onAuthorizationFailure: onFailure, onAuthorized: { _ in },
                            send: { beforeBroadcastAttempt in
                                try await beforeBroadcastAttempt()
                                sent = true
                            }
                        )
                    }
                }
                if expiryStage != "preparation" {
                    try await waitUntil { await sdk.linkedPeersIsPaused() }
                    if expiryStage == "authorization" { clock.advance(by: 0.001) }
                    await sdk.resumeLinkedPeers()
                }
                do {
                    try await execution.value
                    XCTAssertFalse(crossesDeadline, route)
                } catch {
                    XCTAssertTrue(crossesDeadline, route)
                    XCTAssertEqual(error as? PaykitPaymentRequestError, .requestExpired, route)
                }
                XCTAssertEqual(sent, !crossesDeadline, route)
                XCTAssertEqual(authorizationFailed, crossesDeadline, route)
            }
        }
    }

    func testPaymentDeadlineIsCheckedInsideTheLdkSubmissionQueue() async throws {
        for crossesDeadline in [false, true] {
            let clock = PaymentRequestTestClock(Date(timeIntervalSince1970: 1_800_000_000))
            let deadline = PaykitPreciseInstant(date: clock.now().addingTimeInterval(1))
            let blocked = expectation(description: "LDK queue blocked")
            let submissionStarted = expectation(description: "submission queued")
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let blocker = Task {
                try await Bitkit.ServiceQueue.background(.ldk) {
                    blocked.fulfill()
                    XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                }
            }
            await fulfillment(of: [blocked], timeout: 2)
            let submission = Task {
                submissionStarted.fulfill()
                return try await Bitkit.LightningService.submitPayment(beforeSubmission: {
                    try PaykitPaymentRequest.checkPaymentDeadline(deadline, at: clock.now())
                }) { "submitted" }
            }
            await fulfillment(of: [submissionStarted], timeout: 2)
            clock.advance(by: crossesDeadline ? 1.001 : 1)
            release.signal()
            try await blocker.value
            do {
                let result = try await submission.value
                XCTAssertFalse(crossesDeadline)
                XCTAssertEqual(result, "submitted")
            } catch {
                XCTAssertTrue(crossesDeadline)
                XCTAssertEqual((error as? Bitkit.AppError)?.underlyingError as? PaykitPaymentRequestError, .requestExpired)
                XCTAssertTrue(PaykitPaymentProofService.isDefiniteOnchainPreBroadcastFailure(error))
                XCTAssertEqual(SendConfirmationView.privatePaymentListOutcomeAfterFailure(
                    currentOutcome: .uncertain, walletType: .onchain, onchainPaymentStarted: true, error: error
                ), .uncertain, "A raw queue error cannot release a started payment; only the typed pre-dispatch result proves no broadcast")
            }
        }
    }

    func testExpiredAcceptedRequestIsNotReinsertedAfterSdkLookup() async throws {
        for isRetry in [false, true] {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let clock = PaymentRequestTestClock(now)
            var record = try paymentRequestRecord(paymentDeadline: .at(timestamp: timestamp(now.addingTimeInterval(1))))
            let sdk = PaymentRequestSdkMock(records: [record])
            let manager = paymentRequestManager(sdk: sdk, clock: clock)
            await manager.refresh()
            let request = try XCTUnwrap(manager.pendingRequests.first)
            try await manager.prepareForPayment(request)
            record.state = .accepted
            await sdk.setRecords([record])
            XCTAssertTrue(manager.pendingRequests.isEmpty)
            await sdk.pauseNextPaymentRequestList()
            let lookup = Task {
                if isRetry {
                    let retried = await manager.paymentRequestForRetry(request.id)
                    XCTAssertNil(retried)
                } else {
                    await manager.finishPayment(request)
                }
            }
            try await waitUntil { await sdk.paymentRequestListIsPaused() }
            clock.advance(by: 2)
            await sdk.resumePaymentRequestList()
            await lookup.value
            XCTAssertTrue(manager.pendingRequests.isEmpty)
            XCTAssertFalse(manager.isApprovedForPayment(request))
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
        let firstMessages = recorder.messages
        _ = try await service.synchronize()

        XCTAssertTrue(snapshot.incoming.isEmpty)
        let output = recorder.messages.joined(separator: "\n")
        XCTAssertEqual(recorder.messages, firstMessages)
        XCTAssertTrue(output.contains("category=parse reason=unsupported_asset"))
        XCTAssertTrue(output.contains("category=parse reason=no_supported_endpoint"))
        XCTAssertFalse(output.contains("category=parse reason=unsupported_local_role"))
        XCTAssertTrue(output.contains("counterparty=\(PaykitPaymentRequestDiagnostics.redactedCounterparty(counterparty))"))
        XCTAssertFalse(output.contains("counterparty=\(PaykitPaymentRequestDiagnostics.redactedCounterparty(unknownRoleCounterparty))"))
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
            paymentRequestRecord(id: "deadline-proposed", paymentDeadline: .at(timestamp: timestamp(now.addingTimeInterval(-1)))),
            paymentRequestRecord(id: "deadline-accepted", state: .accepted, paymentDeadline: .at(timestamp: timestamp(now.addingTimeInterval(-1)))),
            paymentRequestRecord(id: "deadline-paid", state: .proofSubmitted, paymentDeadline: .at(timestamp: timestamp(now.addingTimeInterval(-1)))),
            paymentRequestRecord(id: "deadline-canceled", state: .canceled, paymentDeadline: .at(timestamp: timestamp(now.addingTimeInterval(-1)))),
            paymentRequestRecord(id: "deadline-rejected", state: .rejected, paymentDeadline: .at(timestamp: timestamp(now.addingTimeInterval(-1)))),
        ]
        let manager = paymentRequestManager(
            sdk: PaymentRequestSdkMock(records: records),
            clock: PaymentRequestTestClock(now)
        )

        await manager.refresh()

        XCTAssertEqual(manager.pendingRequests.map(\.paymentRequestId), ["incoming"])
        XCTAssertEqual(
            Set(manager.historyRequests.map(\.paymentRequestId)),
            Set([
                "incoming", "accepted", "rejected", "expired", "outgoing", "unsupported",
                "deadline-proposed", "deadline-accepted", "deadline-paid", "deadline-canceled", "deadline-rejected",
            ])
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

    func testStoredRefreshMapsActiveRecurringRequestAndCurrentUnpaidPeriod() async throws {
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
        let sdk = PaymentRequestSdkMock(records: [record])
        let manager = paymentRequestManager(sdk: sdk, clock: PaymentRequestTestClock(now))

        await manager.refresh(mode: .stored)

        let snapshot = await sdk.snapshot()
        XCTAssertEqual(snapshot.processCallCount, 0)
        XCTAssertEqual(snapshot.receiveCallCount, 0)
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

    func testPaidSubscriptionPeriodStaysBlockedWhileNextUnpaidPeriodIsAuthorized() async throws {
        actor InFlightPayments {
            var ids = Set<PaykitPaymentRequest.ID>()

            func insert(_ id: PaykitPaymentRequest.ID) {
                ids.insert(id)
            }

            func clear() {
                ids = []
            }
        }

        let clock = try PaymentRequestTestClock(XCTUnwrap(PaykitPaymentRequest.parseDate("2027-01-15T08:00:00Z")))
        let method = PublicPaykitService.MethodId.regtestOnchainP2wpkh
        var record = try paymentRequestRecord(
            state: .activeRecurring,
            recurrence: PaymentRequestRecurrence(
                every: 1, unit: "month", startsAt: "2027-01-01T08:00:00Z", anchor: "2027-01-01T08:00:00Z", endsAt: nil
            ),
            endpoints: [method.rawValue],
            paymentEndpoints: [method.rawValue: PublicPaykitService.serializePayload(value: "bcrt1qfn50lqawrce0evh66qrnlt8j447lwmeyqp5gmd")]
        )
        let sdk = PaymentRequestSdkMock(records: [record])
        let inFlightPayments = InFlightPayments()
        let manager = PaykitPaymentRequestManager(
            scheduleAcceptedRequestDelivery: { _ in },
            service: PaykitPaymentRequestService(sdk: sdk, now: { clock.now() }, logWarning: { _ in }),
            presentationStore: PaymentRequestPresentationMemoryStore(),
            acceptanceStore: PaymentRequestPresentationMemoryStore(),
            subscriptionStateStore: PaymentRequestSubscriptionStateMemoryStore(),
            completedPaymentProofKinds: { _ in [:] },
            inFlightPaymentRequestIds: { _ in await inFlightPayments.ids },
            now: { clock.now() },
            isAvailable: { true },
            logWarning: { _ in }
        )
        manager.activate(identity: "pubky\(String(repeating: "z", count: 52))")
        await manager.refresh()
        let firstPeriod = try XCTUnwrap(manager.pendingRequests.first)
        try await manager.prepareForPayment(firstPeriod)
        try await manager.ensurePaymentAllowed(firstPeriod)
        await inFlightPayments.insert(firstPeriod.id)
        await manager.refresh()
        XCTAssertTrue(manager.pendingRequests.isEmpty)
        try await manager.ensurePaymentAllowed(firstPeriod)
        await manager.finishPayment(firstPeriod)
        await inFlightPayments.clear()
        await manager.refresh(mode: .stored)
        XCTAssertEqual(manager.pendingRequests.map(\.id), [firstPeriod.id])
        record.paymentProofs = try [paymentProofRecord(
            endpoint: method.rawValue, kind: .onchain, billingPeriod: XCTUnwrap(firstPeriod.billingPeriod).sdkValue
        )]
        record.paymentProofs[0].outboundStatus = .pending
        await sdk.setRecords([record])
        XCTAssertTrue(try XCTUnwrap(manager.subscriptions.first).paidPeriods.isEmpty)
        do {
            try await manager.prepareForPayment(firstPeriod) {
                XCTFail("A paid billing period must not consume another payment destination")
            }
            XCTFail("A queued proof must prevent another payment before refreshing")
        } catch {
            XCTAssertEqual(error as? PaykitPaymentRequestError, .requestUnavailable)
        }
        clock.advance(by: 31 * 24 * 60 * 60)
        await manager.refresh()

        do {
            try await manager.ensurePaymentAllowed(firstPeriod)
            XCTFail("A paid billing period must not authorize another payment")
        } catch {
            XCTAssertEqual(error as? PaykitPaymentRequestError, .requestUnavailable)
        }
        do {
            try await manager.prepareForPayment(firstPeriod)
            XCTFail("A paid billing period must not be approved again")
        } catch {
            XCTAssertEqual(error as? PaykitPaymentRequestError, .requestUnavailable)
        }
        let nextPeriod = try XCTUnwrap(manager.pendingRequests.first)
        XCTAssertEqual(nextPeriod.billingPeriod?.sdkValue.startsAt, "2027-02-01T08:00:00Z")
        try await manager.prepareForPayment(nextPeriod)
        try await manager.ensurePaymentAllowed(nextPeriod)
    }

    func testCanceledSubscriptionCannotAuthorizeAnApprovedPeriod() async throws {
        let clock = try PaymentRequestTestClock(XCTUnwrap(PaykitPaymentRequest.parseDate("2027-01-15T08:00:00Z")))
        var record = try paymentRequestRecord(
            state: .activeRecurring,
            recurrence: PaymentRequestRecurrence(
                every: 1, unit: "month", startsAt: "2027-01-01T08:00:00Z", anchor: "2027-01-01T08:00:00Z", endsAt: nil
            )
        )
        let sdk = PaymentRequestSdkMock(records: [record])
        let manager = paymentRequestManager(sdk: sdk, clock: clock)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        try await manager.prepareForPayment(request)
        XCTAssertTrue(manager.isApprovedForPayment(request))
        await sdk.pauseNextLinkedPeers()

        let authorization = Task { try await manager.ensurePaymentAllowed(request) }
        try await waitUntil { await sdk.linkedPeersIsPaused() }
        record.state = .canceled
        await sdk.setRecords([record])
        await manager.refresh(mode: .stored)
        await sdk.resumeLinkedPeers()

        XCTAssertFalse(manager.isApprovedForPayment(request))
        do {
            try await authorization.value
            XCTFail("A canceled subscription must not authorize payment")
        } catch {
            XCTAssertEqual(error as? PaykitPaymentRequestError, .requestUnavailable)
        }
        do {
            try await manager.prepareForPayment(request)
            XCTFail("A canceled subscription must not be approved again")
        } catch {
            XCTAssertEqual(error as? PaykitPaymentRequestError, .requestUnavailable)
        }
    }

    func testRefreshKeepsCreatorSubscriptionWithoutGeneratingPayerPayment() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let record = try paymentRequestRecord(
            id: "creator-recurring",
            state: .activeRecurring,
            role: .payee,
            recurrence: recurrence,
            metadata: #"{"note":"Creator plan","subscription":{"version":1,"description":"Monthly support","benefits":[],"icon_uri":"pubky://creator/icon"}}"#
        )
        let manager = paymentRequestManager(
            sdk: PaymentRequestSdkMock(records: [record]),
            clock: PaymentRequestTestClock(now)
        )

        await manager.refresh()

        let subscription = try XCTUnwrap(manager.subscriptions.first)
        XCTAssertTrue(subscription.isCreatedByUser)
        XCTAssertEqual(subscription.note, "Creator plan")
        XCTAssertEqual(subscription.metadata.description, "Monthly support")
        XCTAssertEqual(subscription.metadata.iconURI, "pubky://creator/icon")
        XCTAssertTrue(manager.pendingRequests.isEmpty)
        XCTAssertTrue(manager.historyRequests.isEmpty)
    }

    func testCreatorPaymentsAggregateDuplicateProofEventsForOneBillingPeriod() throws {
        let period = BillingPeriod(startsAt: "2027-01-01T08:00:00Z", endsAt: "2027-02-01T08:00:00Z")
        let first = try paymentProofRecord(
            endpoint: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning,
            billingPeriod: period
        )
        var second = first
        second.eventId = "850e8400-e29b-41d4-a716-446655440000"
        var offSchedule = first
        offSchedule.eventId = "950e8400-e29b-41d4-a716-446655440000"
        offSchedule.billingPeriod = BillingPeriod(startsAt: period.startsAt, endsAt: "2027-02-02T08:00:00Z")
        let record = try paymentRequestRecord(
            state: .activeRecurring,
            role: .payee,
            recurrence: PaymentRequestRecurrence(
                every: 1,
                unit: "month",
                startsAt: period.startsAt,
                anchor: period.startsAt,
                endsAt: nil
            ),
            paymentProofs: [first, second, offSchedule]
        )
        let subscription = try XCTUnwrap(PaykitSubscription(record: record))
        XCTAssertEqual(subscription.payments.count, 1)
        let received = subscription.receivedPaymentRequests()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.direction, .outgoing)
        XCTAssertEqual(received.first?.lifecycleState, .proofSubmitted)
        XCTAssertEqual(received.first?.paymentProofKind, .lightning)
    }

    func testExpiredCreatorSubscriptionsKeepPaidHistoryAccessible() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-02-15T08:00:00Z"))
        let period = BillingPeriod(startsAt: "2027-01-01T08:00:00Z", endsAt: "2027-02-01T08:00:00Z")
        let proof = try paymentProofRecord(
            endpoint: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning,
            billingPeriod: period
        )
        for state in [PaymentRequestLifecycleState.canceled, .activeRecurring] {
            for hasPayments in [false, true] {
                let record = try paymentRequestRecord(
                    state: state,
                    role: .payee,
                    recurrence: PaymentRequestRecurrence(
                        every: 1,
                        unit: "month",
                        startsAt: period.startsAt,
                        anchor: period.startsAt,
                        endsAt: state == .activeRecurring ? period.endsAt : nil
                    ),
                    paymentProofs: hasPayments ? [proof] : []
                )
                let manager = paymentRequestManager(sdk: PaymentRequestSdkMock(records: [record]), clock: PaymentRequestTestClock(now))
                await manager.refresh()
                let subscription = try XCTUnwrap(manager.subscriptions.first)
                XCTAssertFalse(subscription.isCreatedVisible(at: now))
                XCTAssertEqual(subscription.isExpiredVisible(at: now), hasPayments)
                XCTAssertEqual(subscription.receivedPaymentRequests().count, hasPayments ? 1 : 0)
                XCTAssertFalse(subscription.canCancel(at: now))
                XCTAssertTrue(manager.pendingRequests.isEmpty)
            }
        }
    }

    func testFractionalBillingProofsRemainPaidForCreatorAndPayer() throws {
        for fraction in ["123", "123456789", "999999999"] {
            let first = BillingPeriod(
                startsAt: "2027-01-15T08:00:00.\(fraction)Z",
                endsAt: "2027-02-15T08:00:00.\(fraction)Z"
            )
            let second = BillingPeriod(
                startsAt: first.endsAt,
                endsAt: "2027-03-15T08:00:00.\(fraction)Z"
            )
            let proofs = try [first, second].map {
                try paymentProofRecord(
                    endpoint: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                    kind: .lightning,
                    billingPeriod: $0
                )
            }
            for role in [PaymentRequestLocalRole.payee, .payer] {
                let record = try paymentRequestRecord(
                    state: .activeRecurring,
                    role: role,
                    recurrence: PaymentRequestRecurrence(
                        every: 1,
                        unit: "month",
                        startsAt: first.startsAt,
                        anchor: first.startsAt,
                        endsAt: nil
                    ),
                    paymentProofs: proofs
                )
                let subscription = try XCTUnwrap(PaykitSubscription(record: record))
                XCTAssertEqual(subscription.payments.count, 2)
                let requests = if role == .payee {
                    subscription.receivedPaymentRequests()
                } else {
                    try subscription.requests(
                        through: XCTUnwrap(ISO8601DateFormatter().date(from: "2027-02-16T08:00:00Z")),
                        acceptedAt: PaykitPreciseInstant(
                            date: XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:01Z"))
                        )
                    )
                }
                XCTAssertEqual(requests.count, 2)
                XCTAssertTrue(requests.allSatisfy { $0.lifecycleState == .proofSubmitted })
            }
        }
    }

    func testCreatorProposalBuildsRecurringTermsAndStaysQueuedUntilDelivery() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let expiresAt = now.addingTimeInterval(60)
        let publicKey = "pubky\(String(repeating: "y", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: publicKey, state: .linked)],
            requestCapabilitiesByPublicKey: [publicKey: true]
        )
        try await sdk.setProposalResult(paymentRequestRecord(
            id: "creator-proposal",
            counterparty: publicKey,
            role: .payee
        ))
        let manager = paymentRequestManager(sdk: sdk, clock: PaymentRequestTestClock(now))
        await manager.refreshEligibleTargets(savedPublicKeys: [publicKey])

        let subscription = try await manager.proposeSubscription(
            PaykitSubscriptionDraft(
                amountSats: 100_000,
                name: " Monthly support ",
                description: " Thank you ",
                frequency: .month,
                expiresAt: expiresAt,
                iconData: nil
            ),
            to: XCTUnwrap(manager.eligibleTargets.first)
        )

        let snapshot = await sdk.snapshot()
        let proposed = try XCTUnwrap(snapshot.proposedRequests.first)
        XCTAssertEqual(proposed.amount, "0.001")
        XCTAssertEqual(proposed.asset, PaykitIssuerInterop.bitcoinAsset)
        XCTAssertEqual(proposed.expiresAt, timestamp(expiresAt))
        XCTAssertEqual(proposed.recurrence?.every, 1)
        XCTAssertEqual(proposed.recurrence?.unit, "month")
        XCTAssertEqual(proposed.recurrence?.startsAt, timestamp(now))
        XCTAssertEqual(proposed.recurrence?.anchor, timestamp(now))
        XCTAssertNil(proposed.recurrence?.endsAt)
        let metadataData = try XCTUnwrap(proposed.metadata.data(using: .utf8))
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: metadataData) as? [String: Any])
        XCTAssertEqual(metadata["note"] as? String, "Monthly support")
        let subscriptionMetadata = try XCTUnwrap(metadata["subscription"] as? [String: Any])
        XCTAssertEqual(subscriptionMetadata["description"] as? String, "Thank you")
        XCTAssertTrue(subscription.isCreatedByUser)
        XCTAssertEqual(subscription.deliveryStatus, .queued)
        XCTAssertEqual(manager.subscriptions, [subscription])
    }

    func testCreatedSubscriptionSurvivesContactChangesButNotSessionChanges() async throws {
        let publicKey = "pubky\(String(repeating: "y", count: 52))"
        let otherKey = "pubky\(String(repeating: "a", count: 52))"
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        for change in ["reordered", "removed", "added", "cleared", "identity"] {
            let sdk = PaymentRequestSdkMock(records: [])
            await sdk.configureRecipients(
                peers: [linkedPeer(counterparty: publicKey, state: .linked)],
                requestCapabilitiesByPublicKey: [publicKey: true]
            )
            try await sdk.setProposalResult(paymentRequestRecord(role: .payee))
            let manager = paymentRequestManager(sdk: sdk, clock: PaymentRequestTestClock(now))
            await manager.refreshEligibleTargets(savedPublicKeys: [publicKey, otherKey])
            let target = try XCTUnwrap(manager.eligibleTargets.first)
            await sdk.pauseNextProcess()
            let proposal = Task {
                try await manager.proposeSubscription(
                    PaykitSubscriptionDraft(
                        amountSats: 1000, name: "Support", description: "", frequency: .month,
                        expiresAt: now.addingTimeInterval(60), iconData: nil
                    ),
                    to: target
                )
            }
            try await waitUntil { await sdk.processIsPaused() }
            switch change {
            case "reordered": await manager.refreshEligibleTargets(savedPublicKeys: [otherKey, publicKey])
            case "removed": await manager.refreshEligibleTargets(savedPublicKeys: [])
            case "added": await manager.refreshEligibleTargets(savedPublicKeys: [publicKey, otherKey, String(repeating: "o", count: 52)])
            case "cleared": manager.clear()
            default: manager.activate(identity: otherKey)
            }
            await sdk.resumeProcess()
            let subscription = try await proposal.value
            let snapshot = await sdk.snapshot()
            XCTAssertEqual(snapshot.proposedRequests.count, 1, change)
            XCTAssertEqual(manager.subscriptions, ["cleared", "identity"].contains(change) ? [] : [subscription], change)
            XCTAssertFalse(manager.isCreatingRequest, change)
        }
    }

    func testSubscriptionRevalidatesAfterIconUploadBeforeEnqueue() async throws {
        let publicKey = "pubky\(String(repeating: "y", count: 52))"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.purple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let iconData = try XCTUnwrap(image.pngData())
        let optionKey = PublicPaykitService.lightningPaymentOptionEnabledKey
        let previousOption = UserDefaults.standard.object(forKey: optionKey)
        defer { UserDefaults.standard.set(previousOption, forKey: optionKey) }

        for change in ["unchanged", "expired", "removed", "unlinked", "unsupported", "endpoint", "cleared"] {
            UserDefaults.standard.set(true, forKey: optionKey)
            let clock = PaymentRequestTestClock(now)
            let sdk = PaymentRequestSdkMock(records: [])
            await sdk.configureRecipients(
                peers: [linkedPeer(counterparty: publicKey, state: .linked)],
                requestCapabilitiesByPublicKey: [publicKey: true]
            )
            try await sdk.setProposalResult(paymentRequestRecord(role: .payee))
            let manager = paymentRequestManager(sdk: sdk, clock: clock)
            await manager.refreshEligibleTargets(savedPublicKeys: [publicKey])
            let target = try XCTUnwrap(manager.eligibleTargets.first)
            await sdk.pauseNextUpload()
            let proposal = Task {
                try await manager.proposeSubscription(
                    PaykitSubscriptionDraft(
                        amountSats: 1000, name: "Support", description: "", frequency: .month,
                        expiresAt: now.addingTimeInterval(60), iconData: iconData
                    ),
                    to: target
                )
            }
            try await waitUntil { await sdk.uploadIsPaused() }
            switch change {
            case "expired": clock.advance(by: 60)
            case "removed": await manager.refreshEligibleTargets(savedPublicKeys: [])
            case "unlinked": await sdk.configureRecipients(peers: [], requestCapabilitiesByPublicKey: [publicKey: true])
            case "unsupported":
                await sdk.configureRecipients(
                    peers: [linkedPeer(counterparty: publicKey, state: .linked)],
                    requestCapabilitiesByPublicKey: [:]
                )
            case "endpoint": UserDefaults.standard.set(false, forKey: optionKey)
            case "cleared": manager.clear()
            default: break
            }
            await sdk.resumeUpload()
            do {
                _ = try await proposal.value
                XCTAssertEqual(change, "unchanged")
            } catch {
                XCTAssertNotEqual(change, "unchanged")
                XCTAssertEqual(error as? PaykitPaymentRequestError, change == "expired" ? .requestExpired : .requestUnavailable, change)
            }
            let snapshot = await sdk.snapshot()
            XCTAssertEqual(snapshot.uploadCount, 1, change)
            XCTAssertEqual(snapshot.proposedRequests.count, change == "unchanged" ? 1 : 0, change)
            XCTAssertEqual(manager.subscriptions.count, change == "unchanged" ? 1 : 0, change)
            XCTAssertFalse(manager.isCreatingRequest, change)
        }
    }

    func testOversizedCreatorProposalIsRejectedBeforeIconUploadOrEnqueue() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let publicKey = "pubky\(String(repeating: "y", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: publicKey, state: .linked)],
            requestCapabilitiesByPublicKey: [publicKey: true]
        )
        let manager = paymentRequestManager(sdk: sdk, clock: PaymentRequestTestClock(now))
        await manager.refreshEligibleTargets(savedPublicKeys: [publicKey])
        let target = try XCTUnwrap(manager.eligibleTargets.first)

        for iconData in [nil, Data([0, 1, 2])] as [Data?] {
            do {
                _ = try await manager.proposeSubscription(
                    PaykitSubscriptionDraft(
                        amountSats: 1000,
                        name: "Support",
                        description: String(repeating: "💜", count: 256),
                        frequency: .month,
                        expiresAt: now.addingTimeInterval(60),
                        iconData: iconData
                    ),
                    to: target
                )
                XCTFail("Oversized proposals must be rejected before external writes")
            } catch {
                XCTAssertEqual(error as? PaykitPaymentRequestError, .subscriptionTooLong)
            }
        }

        let snapshot = await sdk.snapshot()
        XCTAssertEqual(snapshot.uploadCount, 0)
        XCTAssertTrue(snapshot.proposedRequests.isEmpty)
        XCTAssertTrue(manager.subscriptions.isEmpty)
        XCTAssertFalse(manager.isCreatingRequest)
    }

    func testCreatorPendingProposalCanBeDeletedButFixedEndProposalCannot() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let openEnded = try XCTUnwrap(PaykitSubscription(record: paymentRequestRecord(
            role: .payee,
            expiresAt: timestamp(now.addingTimeInterval(60)),
            recurrence: PaymentRequestRecurrence(
                every: 1,
                unit: "month",
                startsAt: timestamp(now),
                anchor: timestamp(now),
                endsAt: nil
            )
        )))
        let fixedEnd = try XCTUnwrap(PaykitSubscription(record: paymentRequestRecord(
            role: .payee,
            expiresAt: timestamp(now.addingTimeInterval(60)),
            recurrence: PaymentRequestRecurrence(
                every: 1,
                unit: "month",
                startsAt: timestamp(now),
                anchor: timestamp(now),
                endsAt: timestamp(now.addingTimeInterval(3600))
            )
        )))

        XCTAssertTrue(openEnded.canCancel(at: now))
        XCTAssertFalse(fixedEnd.canCancel(at: now))
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

    func testSubscriptionClockOffsetSurfacesNextSubscriptionPeriodAndKeepsOneTimeRequestsOnRealTime() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let oneMonthLater = now.addingTimeInterval(31 * 24 * 60 * 60)
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-15T08:00:00Z",
            anchor: "2027-01-15T08:00:00Z",
            endsAt: nil
        )
        let firstPeriod = BillingPeriod(startsAt: "2027-01-15T08:00:00Z", endsAt: "2027-02-15T08:00:00Z")
        let records = try [
            paymentRequestRecord(
                id: "recurring",
                state: .activeRecurring,
                recurrence: recurrence,
                acceptedEventId: "accepted",
                paymentProofs: [paymentProofRecord(
                    endpoint: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                    kind: .lightning,
                    billingPeriod: firstPeriod
                )]
            ),
            paymentRequestRecord(id: "one-time", expiresAt: "2027-01-22T08:00:00Z"),
        ]

        let realTimeManager = try paymentRequestManager(
            sdk: PaymentRequestSdkMock(records: records),
            clock: PaymentRequestTestClock(now)
        )
        await realTimeManager.refresh()
        XCTAssertEqual(realTimeManager.pendingRequests.map(\.paymentRequestId), ["one-time"])

        let offsetManager = try paymentRequestManager(
            sdk: PaymentRequestSdkMock(records: records),
            clock: PaymentRequestTestClock(now),
            subscriptionClock: PaymentRequestTestClock(oneMonthLater)
        )
        await offsetManager.refresh()

        let renewal = try XCTUnwrap(offsetManager.pendingRequests.first { $0.paymentRequestId == "recurring" })
        XCTAssertEqual(renewal.billingPeriod?.sdkValue, BillingPeriod(startsAt: "2027-02-15T08:00:00Z", endsAt: "2027-03-15T08:00:00Z"))
        XCTAssertTrue(offsetManager.pendingRequests.contains { $0.paymentRequestId == "one-time" })
        let subscription = try XCTUnwrap(offsetManager.subscriptions.first)
        XCTAssertEqual(subscription.paidPeriods, [PaykitBillingPeriod(sdkPeriod: firstPeriod)])
        XCTAssertTrue(subscription.isActive(at: oneMonthLater))
    }

    func testSubscriptionClockOffsetKeepsProposedRecurrenceOnRealTime() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let oneMonthLater = now.addingTimeInterval(31 * 24 * 60 * 60)
        let publicKey = "pubky\(String(repeating: "y", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: publicKey, state: .linked)],
            requestCapabilitiesByPublicKey: [publicKey: true]
        )
        try await sdk.setProposalResult(paymentRequestRecord(
            id: "creator-proposal",
            counterparty: publicKey,
            role: .payee
        ))
        let manager = paymentRequestManager(
            sdk: sdk,
            clock: PaymentRequestTestClock(now),
            subscriptionClock: PaymentRequestTestClock(oneMonthLater)
        )
        await manager.refreshEligibleTargets(savedPublicKeys: [publicKey])
        let target = try XCTUnwrap(manager.eligibleTargets.first)
        var draft = PaykitSubscriptionDraft(
            amountSats: 2000,
            name: "Tee Club",
            description: "",
            frequency: .month,
            expiresAt: now.addingTimeInterval(7 * 24 * 60 * 60),
            iconData: nil
        )

        draft.expiresAt = now.addingTimeInterval(-60)
        do {
            _ = try await manager.proposeSubscription(draft, to: target)
            XCTFail("A proposal that expired in real time must be refused")
        } catch {
            XCTAssertEqual(error as? PaykitPaymentRequestError, .requestExpired)
        }

        draft.expiresAt = now.addingTimeInterval(7 * 24 * 60 * 60)
        _ = try await manager.proposeSubscription(draft, to: target)

        let snapshot = await sdk.snapshot()
        let proposed = try XCTUnwrap(snapshot.proposedRequests.first)
        XCTAssertEqual(proposed.recurrence?.startsAt, timestamp(now))
        XCTAssertEqual(proposed.recurrence?.anchor, timestamp(now))
    }

    func testReviewNamesTheFirstPeriodThatAcceptingPaysUnderTheClockOffset() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-02T08:00:30Z"))
        let oneMonthLater = now.addingTimeInterval(31 * 24 * 60 * 60)
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-02T08:00:00Z",
            anchor: "2027-01-02T08:00:00Z",
            endsAt: nil
        )
        let subscription = try XCTUnwrap(PaykitSubscription(record: paymentRequestRecord(recurrence: recurrence)))

        let reviewed = try XCTUnwrap(subscription.paymentDueOnAcceptance(at: oneMonthLater, acceptedAt: now))

        XCTAssertEqual(reviewed.billingPeriod?.sdkValue.startsAt, "2027-01-02T08:00:00Z")
        XCTAssertEqual(reviewed.billingPeriod?.sdkValue.endsAt, "2027-02-02T08:00:00Z")
    }

    func testAcceptingSubscriptionWithClockOffsetKeepsFirstPeriodDue() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-01T08:00:30Z"))
        let oneMonthLater = now.addingTimeInterval(31 * 24 * 60 * 60)
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord(id: "recurring", recurrence: recurrence)])
        let manager = paymentRequestManager(
            sdk: sdk,
            clock: PaymentRequestTestClock(now),
            subscriptionClock: PaymentRequestTestClock(oneMonthLater)
        )
        await manager.refresh()

        let dueRequest = try await manager.accept(XCTUnwrap(manager.subscriptions.first))

        XCTAssertEqual(dueRequest?.billingPeriod?.sdkValue.startsAt, "2027-01-01T08:00:00Z")
        XCTAssertEqual(
            manager.pendingRequests.compactMap { $0.billingPeriod?.sdkValue.startsAt }.sorted(),
            ["2027-01-01T08:00:00Z", "2027-02-01T08:00:00Z"]
        )
    }

    func testSubscriptionPaymentCanBeReopenedForManualRetry() async throws {
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

        let retriedRequest = await manager.paymentRequestForRetry(request.id)
        XCTAssertEqual(retriedRequest, request)
        XCTAssertTrue(manager.requestPresentation(request))
        XCTAssertEqual(manager.requestedPresentationId, request.id)
    }

    func testAcceptedRequestPastProposalExpirationDoesNotRescheduleExpiration() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = PaymentRequestTestClock(now)
        let record = try paymentRequestRecord(
            state: .accepted,
            expiresAt: timestamp(now.addingTimeInterval(-60))
        )
        let manager = paymentRequestManager(sdk: PaymentRequestSdkMock(records: [record]), clock: clock, acceptedRecords: [record])

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

    func testFailedSubscriptionDismissalKeepsPeriodQueued() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1, unit: "month", startsAt: timestamp(now), anchor: timestamp(now), endsAt: nil
        )
        let store = PaymentRequestSubscriptionStateMemoryStore()
        let manager = try paymentRequestManager(
            sdk: PaymentRequestSdkMock(records: [paymentRequestRecord(state: .activeRecurring, recurrence: recurrence)]),
            clock: PaymentRequestTestClock(now),
            subscriptionStateStore: store
        )
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        manager.requestPresentation(request)
        store.shouldFailSave = true

        XCTAssertFalse(manager.dismissSubscriptionPayment(request))
        XCTAssertEqual(manager.pendingRequests, [request])
        XCTAssertEqual(manager.requestedPresentationId, request.id)
        await manager.refresh()
        XCTAssertEqual(manager.pendingRequests, [request])

        store.shouldFailSave = false
        XCTAssertTrue(manager.dismissSubscriptionPayment(request))
        XCTAssertTrue(manager.pendingRequests.isEmpty)
    }

    func testSubscriptionStateLoadFailureLeavesIdentityInactiveUntilRetry() async throws {
        let subscriptionStore = PaymentRequestSubscriptionStateMemoryStore()
        subscriptionStore.shouldFailLoad = true
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: "month",
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: nil
        )
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord(recurrence: recurrence)])
        let manager = PaykitPaymentRequestManager(
            scheduleAcceptedRequestDelivery: { _ in },
            service: PaykitPaymentRequestService(
                sdk: sdk,
                logWarning: { _ in }
            ),
            presentationStore: PaymentRequestPresentationMemoryStore(),
            acceptanceStore: PaymentRequestPresentationMemoryStore(),
            subscriptionStateStore: subscriptionStore,
            isAvailable: { true },
            logWarning: { _ in }
        )
        let identity = "pubky\(String(repeating: "z", count: 52))"

        manager.activate(identity: identity)
        await manager.refresh()

        XCTAssertTrue(manager.subscriptions.isEmpty)
        XCTAssertEqual(subscriptionStore.saveCallCount, 0)

        subscriptionStore.shouldFailLoad = false
        manager.activate(identity: identity)
        await manager.refresh()

        XCTAssertEqual(manager.subscriptions.count, 1)
        XCTAssertEqual(subscriptionStore.saveCallCount, 0)
    }

    func testSubscriptionDeadlinesExpireWithoutAnotherRefresh() async throws {
        let deadline = Date().addingTimeInterval(2)
        let recurrence = PaymentRequestRecurrence(
            every: 1, unit: "month", startsAt: timestamp(Date()), anchor: timestamp(Date()), endsAt: timestamp(deadline)
        )
        let sdk = try PaymentRequestSdkMock(records: [
            paymentRequestRecord(id: "proposal-deadline", expiresAt: timestamp(deadline), recurrence: PaymentRequestRecurrence(
                every: 1, unit: "month", startsAt: timestamp(Date()), anchor: timestamp(Date()), endsAt: nil
            )),
            paymentRequestRecord(id: "schedule-end", recurrence: recurrence),
        ])
        let manager = PaykitPaymentRequestManager(
            scheduleAcceptedRequestDelivery: { _ in },
            service: PaykitPaymentRequestService(sdk: sdk, logWarning: { _ in }),
            presentationStore: PaymentRequestPresentationMemoryStore(),
            acceptanceStore: PaymentRequestPresentationMemoryStore(),
            subscriptionStateStore: PaymentRequestSubscriptionStateMemoryStore(),
            isAvailable: { true },
            logWarning: { _ in }
        )
        manager.activate(identity: "pubky\(String(repeating: "z", count: 52))")
        await manager.refresh()
        XCTAssertEqual(manager.subscriptions.count, 2)
        XCTAssertNotNil(manager.subscriptionProposalForPresentation())

        try await waitUntil(timeout: .seconds(5)) {
            manager.subscriptions.allSatisfy { $0.lifecycleState == .proposalExpired }
        }
        XCTAssertNil(manager.subscriptionProposalForPresentation())
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
        let record = try paymentRequestRecord(
            state: .activeRecurring, recurrence: recurrence
        )
        let subscription = try XCTUnwrap(PaykitSubscription(record: record))
        let request = try XCTUnwrap(subscription.requests(through: now, acceptedAt: PaykitPreciseInstant(date: now)).first)
        let sdk = PaymentRequestSdkMock(records: [record])
        let manager = paymentRequestManager(
            sdk: sdk,
            clock: PaymentRequestTestClock(now),
            completedPaymentProofKinds: [request.id: .lightning]
        )

        await manager.refresh(mode: .stored, forceFresh: true)

        XCTAssertTrue(manager.pendingRequests.isEmpty)
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)
        XCTAssertEqual(manager.historyRequests.first?.id, request.id)
        XCTAssertEqual(manager.historyRequests.first?.lifecycleState, .proofSubmitted)
        XCTAssertEqual(manager.historyRequests.first?.paymentProofKind, .lightning)
        let snapshot = await sdk.snapshot()
        XCTAssertEqual(snapshot.processCallCount, 0)
        XCTAssertEqual(snapshot.receiveCallCount, 0)
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
            let isAvailable = manager.pendingRequests.contains { $0.id == request.id } || manager.isApprovedForPayment(request)
            XCTAssertFalse(isAvailable)
            XCTAssertFalse(SendSheet.shouldDismissUnavailableRequest(
                root: .confirm, path: [], isSubmittingPayment: true, isAvailable: isAvailable
            ))
            for result in [SendRoute.pending(paymentHash: nil, retryRoute: .confirm, paymentRequest: nil), .success(paymentId: "payment")] {
                XCTAssertFalse(SendSheet.shouldDismissUnavailableRequest(
                    root: .confirm, path: [result], isSubmittingPayment: false, isAvailable: isAvailable
                ))
            }
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

    func testDeadlineSubscriptionsKeepPaidPeriodsAndCancellationWithoutOfferingPayments() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-02-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1, unit: "month", startsAt: "2027-01-01T08:00:00Z", anchor: "2027-01-01T08:00:00Z", endsAt: nil
        )
        let proof = try paymentProofRecord(
            endpoint: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning,
            billingPeriod: BillingPeriod(startsAt: "2027-01-01T08:00:00Z", endsAt: "2027-02-01T08:00:00Z")
        )
        let records = try [PaymentRequestLocalRole.payer, .payee].map { (role: PaymentRequestLocalRole) in
            try paymentRequestRecord(
                id: "deadline-\(role)", state: .activeRecurring, role: role,
                paymentDeadline: .periodStart(seconds: 3600), recurrence: recurrence, paymentProofs: [proof]
            )
        }
        let center = PaykitSubscriptionNotificationCenterMock()
        let scheduler = PaykitSubscriptionNotificationScheduler(center: center)
        let manager = paymentRequestManager(
            sdk: PaymentRequestSdkMock(records: records), clock: PaymentRequestTestClock(now)
        )

        await manager.refresh()

        XCTAssertTrue(manager.pendingRequests.isEmpty)
        XCTAssertEqual(manager.subscriptions.count, 2)
        for subscription in manager.subscriptions {
            XCTAssertEqual(subscription.paidPeriods.count, 1)
            XCTAssertTrue(subscription.canCancel(at: now))
            XCTAssertNil(subscription.paymentDueOnAcceptance(at: now))
        }
        let paid = try XCTUnwrap(manager.historyRequests.first)
        XCTAssertEqual(manager.historyRequests.count, 1)
        XCTAssertEqual(paid.lifecycleState, .proofSubmitted)
        XCTAssertEqual(paid.paymentProofKind, .lightning)
        XCTAssertEqual(manager.subscriptions.first { $0.isCreatedByUser }?.receivedPaymentRequests().count, 1)
        await scheduler.synchronize(
            manager.subscriptions,
            acceptedAt: Dictionary(uniqueKeysWithValues: manager.subscriptions.map { ($0.id, PaykitPreciseInstant(date: now)) }),
            pendingRequestIds: [], payerIdentity: "payer", notificationsEnabled: true, now: now
        )
        let pendingNotifications = await center.pendingIdentifiers
        XCTAssertTrue(pendingNotifications.isEmpty)
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
            scheduleAcceptedRequestDelivery: { _ in },
            service: PaykitPaymentRequestService(sdk: sdk, now: { now }, logWarning: { _ in }),
            presentationStore: PaymentRequestPresentationMemoryStore(),
            acceptanceStore: PaymentRequestPresentationMemoryStore(),
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

    func testExpiredSubscriptionEndDateFallsBackToLastPaidPeriod() throws {
        let firstPeriod = BillingPeriod(startsAt: "2027-01-01T08:00:00Z", endsAt: "2027-02-01T08:00:00Z")
        let secondPeriod = BillingPeriod(startsAt: "2027-02-01T08:00:00Z", endsAt: "2027-03-01T08:00:00Z")
        var second = try paymentProofRecord(
            endpoint: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning,
            billingPeriod: secondPeriod
        )
        second.eventId = "850e8400-e29b-41d4-a716-446655440000"
        let first = try paymentProofRecord(
            endpoint: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning,
            billingPeriod: firstPeriod
        )
        let openEnded = try XCTUnwrap(PaykitSubscription(record: paymentRequestRecord(
            state: .activeRecurring,
            role: .payee,
            recurrence: PaymentRequestRecurrence(
                every: 1,
                unit: "month",
                startsAt: firstPeriod.startsAt,
                anchor: firstPeriod.startsAt,
                endsAt: nil
            ),
            paymentProofs: [first, second]
        )))

        XCTAssertEqual(
            subscriptionEndDate(subscription: openEnded),
            ISO8601DateFormatter().date(from: "2027-03-01T08:00:00Z")
        )
    }

    func testSubscriptionEndDatePrefersItsOwnEndDateOverPaidPeriods() throws {
        let period = BillingPeriod(startsAt: "2027-01-01T08:00:00Z", endsAt: "2027-02-01T08:00:00Z")
        let proof = try paymentProofRecord(
            endpoint: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
            kind: .lightning,
            billingPeriod: period
        )
        let fixedEnd = try XCTUnwrap(PaykitSubscription(record: paymentRequestRecord(
            state: .activeRecurring,
            role: .payee,
            recurrence: PaymentRequestRecurrence(
                every: 1,
                unit: "month",
                startsAt: period.startsAt,
                anchor: period.startsAt,
                endsAt: "2027-06-01T08:00:00Z"
            ),
            paymentProofs: [proof]
        )))

        XCTAssertEqual(
            subscriptionEndDate(subscription: fixedEnd),
            ISO8601DateFormatter().date(from: "2027-06-01T08:00:00Z")
        )
    }

    private func canceledSubscription(
        paid: Bool,
        endsAt: String? = nil,
        role: PaymentRequestLocalRole = .payer
    ) throws -> PaykitSubscription {
        let period = BillingPeriod(startsAt: "2027-01-01T08:00:00Z", endsAt: "2027-02-01T08:00:00Z")
        return try XCTUnwrap(PaykitSubscription(record: paymentRequestRecord(
            state: .canceled,
            role: role,
            amount: "0.000012",
            recurrence: PaymentRequestRecurrence(
                every: 1,
                unit: "month",
                startsAt: period.startsAt,
                anchor: period.startsAt,
                endsAt: endsAt
            ),
            paymentProofs: paid ? [paymentProofRecord(
                endpoint: PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                kind: .lightning,
                billingPeriod: period
            )] : []
        )))
    }

    func testCanceledSubscriptionStaysActiveUntilItsPaidPeriodEnds() throws {
        let canceled = try canceledSubscription(paid: true)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let paidThrough = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-02-01T08:00:00Z"))
        let expiresDate = t("subscriptions__expires_date", variables: ["date": paidThrough.formatted(.dateTime.month(.wide).day())])

        XCTAssertEqual(canceled.statusLabel(at: now), t("subscriptions__active"))
        XCTAssertEqual(canceled.rowSubtitle(at: now), expiresDate)
        XCTAssertEqual(canceled.timingTitle(at: now), t("subscriptions__expires"))
        XCTAssertTrue(canceled.showsTiming(at: now))
        XCTAssertFalse(canceled.canCancel(at: now))

        XCTAssertEqual(canceled.statusLabel(at: paidThrough), t("subscriptions__expired"))
        XCTAssertEqual(canceled.rowSubtitle(at: paidThrough), t("subscriptions__expired"))
        XCTAssertEqual(canceled.timingTitle(at: paidThrough), t("subscriptions__expired"))
    }

    func testCanceledSubscriptionMovesFromActiveToExpiredSectionAtThePaidThroughDate() throws {
        let canceled = try canceledSubscription(paid: true)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let paidThrough = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-02-01T08:00:00Z"))

        var sections = subscriptionSections(subscriptions: [canceled], now: now)
        XCTAssertEqual(sections.active.map(\.id), [canceled.id])
        XCTAssertTrue(sections.expired.isEmpty)
        XCTAssertEqual(subscriptionMonthlyCostSats(subscriptions: [canceled], now: now), 1200)

        sections = subscriptionSections(subscriptions: [canceled], now: paidThrough)
        XCTAssertTrue(sections.active.isEmpty)
        XCTAssertEqual(sections.expired.map(\.id), [canceled.id])
        XCTAssertEqual(subscriptionMonthlyCostSats(subscriptions: [canceled], now: paidThrough), 0)
    }

    func testCanceledSubscriptionEndsAtItsLastPaidPeriodWhateverItsFixedEndDate() throws {
        let canceled = try canceledSubscription(paid: true, endsAt: "2027-06-01T08:00:00Z")
        let beforePaidThrough = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let paidThrough = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-02-01T08:00:00Z"))

        XCTAssertEqual(subscriptionEndDate(subscription: canceled), paidThrough)
        XCTAssertEqual(canceled.statusLabel(at: beforePaidThrough), t("subscriptions__active"))
        XCTAssertEqual(canceled.timingTitle(at: beforePaidThrough), t("subscriptions__expires"))
        XCTAssertEqual(subscriptionNextTransitionDate(subscriptions: [canceled], now: beforePaidThrough), paidThrough)

        XCTAssertEqual(canceled.statusLabel(at: paidThrough), t("subscriptions__expired"))
        XCTAssertEqual(canceled.timingTitle(at: paidThrough), t("subscriptions__expired"))
        XCTAssertEqual(
            canceled.rowSubtitle(at: paidThrough),
            t("subscriptions__expires_date", variables: ["date": paidThrough.formatted(.dateTime.month(.wide).day())])
        )
        XCTAssertTrue(subscriptionSections(subscriptions: [canceled], now: paidThrough).active.isEmpty)
        XCTAssertEqual(subscriptionSections(subscriptions: [canceled], now: paidThrough).expired.map(\.id), [canceled.id])
        XCTAssertEqual(subscriptionMonthlyCostSats(subscriptions: [canceled], now: paidThrough), 0)
    }

    func testCanceledSubscriptionCreatedByTheUserStaysCreatedUntilPaidThroughThenExpires() throws {
        let canceled = try canceledSubscription(paid: true, role: .payee)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let paidThrough = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-02-01T08:00:00Z"))
        let expiresDate = t("subscriptions__expires_date", variables: ["date": paidThrough.formatted(.dateTime.month(.wide).day())])

        var sections = subscriptionSections(subscriptions: [canceled], now: now)
        XCTAssertEqual(sections.created.map(\.id), [canceled.id])
        XCTAssertTrue(sections.active.isEmpty)
        XCTAssertTrue(sections.expired.isEmpty)
        XCTAssertEqual(canceled.statusLabel(at: now), t("subscriptions__active"))
        XCTAssertEqual(canceled.rowSubtitle(at: now), expiresDate)
        XCTAssertEqual(canceled.timingTitle(at: now), t("subscriptions__expires"))
        XCTAssertEqual(subscriptionNextTransitionDate(subscriptions: [canceled], now: now), paidThrough)
        XCTAssertEqual(subscriptionMonthlyCostSats(subscriptions: [canceled], now: now), 0)
        XCTAssertFalse(canceled.canCancel(at: now))

        sections = subscriptionSections(subscriptions: [canceled], now: paidThrough)
        XCTAssertTrue(sections.created.isEmpty)
        XCTAssertTrue(sections.active.isEmpty)
        XCTAssertEqual(sections.expired.map(\.id), [canceled.id])
        XCTAssertEqual(canceled.statusLabel(at: paidThrough), t("subscriptions__expired"))
        XCTAssertEqual(canceled.timingTitle(at: paidThrough), t("subscriptions__expired"))
    }

    func testCanceledCreatorSubscriptionWithoutPaymentsStaysUnlisted() throws {
        let canceled = try canceledSubscription(paid: false, role: .payee)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))

        let sections = subscriptionSections(subscriptions: [canceled], now: now)
        XCTAssertTrue(sections.created.isEmpty)
        XCTAssertTrue(sections.active.isEmpty)
        XCTAssertTrue(sections.expired.isEmpty)
    }

    func testCanceledSubscriptionTimerFlipsAtThePaidThroughDate() throws {
        let canceled = try canceledSubscription(paid: true)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))

        XCTAssertEqual(
            subscriptionNextTransitionDate(subscriptions: [canceled], now: now),
            ISO8601DateFormatter().date(from: "2027-02-01T08:00:00Z")
        )
    }

    func testCanceledSubscriptionWithoutPaidPeriodIsExpiredWithoutEndDate() throws {
        let canceled = try canceledSubscription(paid: false)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))

        XCTAssertNil(subscriptionEndDate(subscription: canceled))
        XCTAssertFalse(canceled.showsTiming(at: now))
        XCTAssertEqual(canceled.statusLabel(at: now), t("subscriptions__expired"))
        XCTAssertEqual(canceled.rowSubtitle(at: now), t("subscriptions__expired"))
        XCTAssertNil(subscriptionNextTransitionDate(subscriptions: [canceled], now: now))
    }

    func testRejectedSubscriptionWithFutureEndDateStaysExpired() throws {
        let rejected = try XCTUnwrap(PaykitSubscription(record: paymentRequestRecord(
            state: .rejected,
            recurrence: PaymentRequestRecurrence(
                every: 1,
                unit: "month",
                startsAt: "2027-01-01T08:00:00Z",
                anchor: "2027-01-01T08:00:00Z",
                endsAt: "2027-06-01T08:00:00Z"
            )
        )))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))

        XCTAssertEqual(rejected.statusLabel(at: now), t("subscriptions__expired"))
        XCTAssertEqual(rejected.timingTitle(at: now), t("subscriptions__expired"))
    }

    func testActiveAndEndedSubscriptionsKeepTheirStatusAndTiming() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        func subscription(endsAt: String?) throws -> PaykitSubscription {
            try XCTUnwrap(PaykitSubscription(record: paymentRequestRecord(
                state: .activeRecurring,
                recurrence: PaymentRequestRecurrence(
                    every: 1,
                    unit: "month",
                    startsAt: "2027-01-01T08:00:00Z",
                    anchor: "2027-01-01T08:00:00Z",
                    endsAt: endsAt
                )
            )))
        }
        let openEnded = try subscription(endsAt: nil)
        let fixedEnd = try subscription(endsAt: "2027-06-01T08:00:00Z")
        let ended = try subscription(endsAt: "2027-01-10T08:00:00Z")

        XCTAssertEqual(openEnded.statusLabel(at: now), t("subscriptions__active"))
        XCTAssertEqual(openEnded.timingTitle(at: now), t("subscriptions__renews"))
        XCTAssertEqual(fixedEnd.timingTitle(at: now), t("subscriptions__expires"))
        XCTAssertEqual(ended.statusLabel(at: now), t("subscriptions__expired"))
        XCTAssertEqual(ended.timingTitle(at: now), t("subscriptions__expired"))
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

        let periods = schedule.periods(through: through, acceptedAt: PaykitPreciseInstant(date: acceptedAt))

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

        let period = try XCTUnwrap(
            schedule.periods(through: through, acceptedAt: PaykitPreciseInstant(date: acceptedAt)).first
        )

        XCTAssertEqual(period.startsAt, acceptedAt)
        XCTAssertEqual(period.endsAt, try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z")))
    }

    func testTravelAndDaylightSavingChangesPreserveUTCBillingReminders() async throws {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-03-13T09:00:00Z"))
        let expected = try [
            XCTUnwrap(ISO8601DateFormatter().date(from: "2027-03-14T08:00:00Z")),
            XCTUnwrap(ISO8601DateFormatter().date(from: "2027-03-15T08:00:00Z")),
        ]
        for zone in ["America/New_York", "Pacific/Kiritimati", "Pacific/Pago_Pago"] {
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: zone))
            let recurrence = PaymentRequestRecurrence(
                every: 1, unit: "day", startsAt: "2027-03-13T08:00:00Z",
                anchor: "2027-03-13T08:00:00Z", endsAt: "2027-03-16T08:00:00Z"
            )
            let subscription = try XCTUnwrap(PaykitSubscription(record: paymentRequestRecord(
                state: .activeRecurring, recurrence: recurrence
            )))
            let periods = subscription.recurrence.upcomingPeriods(after: now, limit: 2)
            XCTAssertEqual(periods.map(\.startsAt), expected, zone)
            let center = PaykitSubscriptionNotificationCenterMock()
            let scheduler = PaykitSubscriptionNotificationScheduler(center: center)
            let identifier = PaykitSubscriptionNotificationIdentifier.identifier(
                identity: "pubky_test", subscription: subscription, period: periods[0]
            )
            try await center.add(UNNotificationRequest(
                identifier: identifier, content: UNMutableNotificationContent(),
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)
            ))

            for clock in [now, now.addingTimeInterval(-3600)] {
                await scheduler.synchronize(
                    [subscription], acceptedAt: [subscription.id: PaykitPreciseInstant(date: now)], pendingRequestIds: [],
                    payerIdentity: "pubky_test", notificationsEnabled: true, now: clock
                )
                let requests = await center.pendingNotificationRequests()
                let request = try XCTUnwrap(requests.first { $0.identifier == identifier })
                let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
                XCTAssertEqual(trigger.dateComponents.timeZone?.secondsFromGMT(), 0)
                XCTAssertEqual(trigger.dateComponents.date, expected[0], zone)
                XCTAssertFalse(trigger.repeats)
            }
        }
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

        let period = try XCTUnwrap(
            schedule.periods(through: through, acceptedAt: PaykitPreciseInstant(date: acceptedAt)).first
        )

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

        XCTAssertTrue(schedule.periods(through: start, acceptedAt: PaykitPreciseInstant(date: start)).isEmpty)
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
                paymentRequestRecord(id: "deadline", paymentDeadline: .periodStart(seconds: 3600), recurrence: recurrence),
                paymentRequestRecord(id: "unsupported", recurrence: recurrence, endpoints: ["btc-unsupported-method"]),
                paymentRequestRecord(id: "ended", recurrence: endedRecurrence),
            ]),
            clock: PaymentRequestTestClock(expiration)
        )

        await manager.refresh()

        let deadlineSubscription = try XCTUnwrap(manager.subscriptions.first { $0.paymentRequestId == "deadline" })
        let subscription = try XCTUnwrap(manager.subscriptions.first { $0.paymentRequestId == "unsupported" })
        XCTAssertFalse(subscription.isProposalActionable(at: expiration))
        XCTAssertFalse(deadlineSubscription.isProposalActionable(at: expiration))
        XCTAssertNil(deadlineSubscription.paymentDueOnAcceptance(at: expiration))
        XCTAssertEqual(manager.subscriptionProposalForPresentation()?.id, deadlineSubscription.id)
        do {
            _ = try await manager.accept(deadlineSubscription)
            XCTFail("Unsupported payment terms must not be accepted")
        } catch {
            XCTAssertEqual(error as? PaykitPaymentRequestError, .requestUnavailable)
        }
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
        XCTAssertTrue(request.acceptsLightningInvoiceAmount(satoshis: 0))
        XCTAssertTrue(request.acceptsLightningInvoiceAmount(satoshis: 2500))
        XCTAssertFalse(request.acceptsLightningInvoiceAmount(satoshis: 2501))
    }

    func testLnurlRequestValidatesBoundsAndCapacityBeforeOpeningPayment() throws {
        let request = try XCTUnwrap(PaykitPaymentRequest(record: paymentRequestRecord(amount: "0.000025"), now: Date()))
        var hasCapacity = false
        var checkedAmount: UInt64?
        let app = AppViewModel(
            sheetViewModel: SheetViewModel(),
            navigationViewModel: NavigationViewModel(),
            scanPaymentOperations: ScanPaymentOperations(
                state: {
                    ScanPaymentState(
                        isNodeRunning: true,
                        spendableOnchainBalanceSats: 0,
                        totalLightningBalanceSats: 10000,
                        hasChannels: true,
                        hasUsableChannels: true
                    )
                },
                canSendLightning: {
                    checkedAmount = $0
                    return hasCapacity
                }
            )
        )
        XCTAssertTrue(app.claimContactPaymentContext(ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request)))
        var data = LnurlPayData(
            uri: "https://example.com/pay", callback: "https://example.com/callback",
            minSendable: 1_000_000, maxSendable: 5_000_000,
            metadataStr: "[]", commentAllowed: nil, allowsNostr: false, nostrPubkey: nil
        )

        try app.handleLnurlPayInvoice(data)
        XCTAssertEqual(checkedAmount, request.amountSats)
        XCTAssertTrue(app.didRejectScannedPaymentForInsufficientBalance)
        XCTAssertNil(app.lnurlPayData)

        hasCapacity = true
        for bounds in [(UInt64(1_000_000), UInt64(2_000_000)), (3_000_000, 5_000_000)] {
            data.minSendable = bounds.0
            data.maxSendable = bounds.1
            XCTAssertThrowsError(try app.handleLnurlPayInvoice(data)) {
                XCTAssertEqual($0 as? PaykitPaymentRequestError, .amountMismatch)
            }
            XCTAssertNil(app.lnurlPayData)
        }

        data.minSendable = 1_000_000
        data.maxSendable = 5_000_000
        try app.handleLnurlPayInvoice(data)
        XCTAssertNotNil(app.lnurlPayData)
        XCTAssertEqual(app.selectedWalletToPayFrom, .lightning)
    }

    func testRefreshContinuesWhenPendingResponseDeliveryFails() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        await sdk.failNextProcess()
        let manager = paymentRequestManager(sdk: sdk)

        await manager.refresh(messagePriority: .background)

        XCTAssertEqual(manager.pendingRequests.count, 1)
        let snapshot = await sdk.snapshot()
        XCTAssertEqual(snapshot.processCallCount, 1)
        XCTAssertEqual(snapshot.receiveCallCount, 1)
        let priorities = await sdk.operationPriorities
        XCTAssertEqual(priorities["pending"], [.background])
        XCTAssertEqual(priorities["receive"], [.background])
    }

    func testFailedRefreshKeepsPreviouslyLoadedRequests() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        await sdk.setRecords([])
        await sdk.setReceiveError(.receive)

        await manager.refresh()

        XCTAssertEqual(manager.pendingRequests.count, 1)
        await sdk.setReceiveError(nil)
        await manager.refresh()
        XCTAssertTrue(manager.pendingRequests.isEmpty)
    }

    func testPeerIntakeFailureDoesNotDropReceivedRequests() async throws {
        let record = try paymentRequestRecord()
        let sdk = PaymentRequestSdkMock(records: [record])
        await sdk.setReceiveReports([
            PrivateStreamCounterpartyIntakeReport(
                counterparty: record.counterparty,
                report: nil,
                error: PaymentRequestIntakeError(noPointer: .init())
            ),
        ])
        let manager = paymentRequestManager(sdk: sdk)

        await manager.refresh()

        XCTAssertEqual(manager.pendingRequests.count, 1)
    }

    func testManagerDropsRequestWhenItExpiresWithoutAnotherRefresh() async throws {
        let expiresAt = Date().addingTimeInterval(2)
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord(expiresAt: timestamp(expiresAt))])
        let now: @Sendable () -> Date = { Date() }
        let manager = PaykitPaymentRequestManager(
            scheduleAcceptedRequestDelivery: { _ in },
            service: PaykitPaymentRequestService(sdk: sdk, now: now, logWarning: { _ in }),
            acceptanceStore: PaymentRequestPresentationMemoryStore(),
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

    func testPendingPrivateLinkRecoveryReleasesRequestedPresentationForRetry() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        XCTAssertTrue(manager.requestPresentation(request))

        let feedback = try XCTUnwrap(
            IncomingPaykitPaymentRequestPresentationDispatcher.finishPendingPrivateLink(for: request, with: manager)
        )

        XCTAssertNil(manager.requestedPresentationId)
        XCTAssertEqual(manager.pendingRequests, [request])
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)
        XCTAssertEqual(feedback.diagnosticReason, .paymentDetailsPending)
        XCTAssertNotNil(feedback.toast)
        XCTAssertTrue(manager.requestPresentation(request))
    }

    func testPendingPrivateLinkRecoveryStopsAutomaticPresentationWithoutToast() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.requestsForPresentation().first)

        let feedback = try XCTUnwrap(
            IncomingPaykitPaymentRequestPresentationDispatcher.finishPendingPrivateLink(for: request, with: manager)
        )

        XCTAssertEqual(manager.pendingRequests, [request])
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)
        XCTAssertNil(feedback.toast)
    }

    func testPendingPrivateLinkRecoverySurvivesRecoveryRefreshAndManagerRecreation() async throws {
        let identity = "pubky\(String(repeating: "y", count: 52))"
        let record = try paymentRequestRecord(state: .accepted, acceptedEventId: "accepted")
        let sdk = PaymentRequestSdkMock(records: [record])
        let presentationStore = PaymentRequestPresentationMemoryStore()
        let acceptanceStore = PaymentRequestPresentationMemoryStore()
        try acceptanceStore.save(
            [PaykitPaymentRequest.ID(paymentRequestId: record.paymentRequestId, counterparty: record.counterparty)],
            identity: identity
        )
        let subscriptionStore = PaymentRequestSubscriptionStateMemoryStore()
        let manager = PaykitPaymentRequestManager(
            scheduleAcceptedRequestDelivery: { _ in },
            service: PaykitPaymentRequestService(sdk: sdk, logWarning: { _ in }),
            presentationStore: presentationStore,
            acceptanceStore: acceptanceStore,
            subscriptionStateStore: subscriptionStore,
            logWarning: { _ in }
        )
        manager.activate(identity: identity)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        XCTAssertTrue(manager.requestPresentation(request))
        XCTAssertNotNil(IncomingPaykitPaymentRequestPresentationDispatcher.finishPendingPrivateLink(for: request, with: manager))

        try await sdk.setRecords([
            paymentRequestRecord(state: .recoveryRequired, acceptedEventId: "accepted"),
        ])
        await manager.refresh()

        let recoveryRequest = try XCTUnwrap(manager.pendingRequests.first)
        XCTAssertEqual(recoveryRequest.lifecycleState, .accepted)
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)

        let restoredManager = PaykitPaymentRequestManager(
            scheduleAcceptedRequestDelivery: { _ in },
            service: PaykitPaymentRequestService(sdk: sdk, logWarning: { _ in }),
            presentationStore: presentationStore,
            acceptanceStore: acceptanceStore,
            subscriptionStateStore: subscriptionStore,
            logWarning: { _ in }
        )
        restoredManager.activate(identity: identity)
        await restoredManager.refresh()

        let restoredRequest = try XCTUnwrap(restoredManager.pendingRequests.first)
        XCTAssertEqual(restoredRequest.lifecycleState, .accepted)
        XCTAssertTrue(restoredManager.requestsForPresentation().isEmpty)
        XCTAssertTrue(restoredManager.requestPresentation(restoredRequest))
        XCTAssertEqual(restoredManager.requestsForPresentation(), [restoredRequest])
    }

    func testRecoveryRequiredIncomingRequestHonorsLocalPaymentProtection() async throws {
        let record = try paymentRequestRecord(state: .recoveryRequired, acceptedEventId: "accepted")
        let request = try XCTUnwrap(PaykitPaymentRequest(record: record, now: Date()))
        let unpaidManager = paymentRequestManager(sdk: PaymentRequestSdkMock(records: [record]), acceptedRecords: [record])
        let completedManager = paymentRequestManager(
            sdk: PaymentRequestSdkMock(records: [record]),
            completedPaymentProofKinds: [request.id: .lightning],
            acceptedRecords: [record]
        )
        let inFlightManager = paymentRequestManager(
            sdk: PaymentRequestSdkMock(records: [record]),
            inFlightPaymentRequestIds: [request.id],
            acceptedRecords: [record]
        )

        await unpaidManager.refresh()
        await completedManager.refresh()
        await inFlightManager.refresh()

        XCTAssertEqual(unpaidManager.pendingRequests, [request])
        XCTAssertTrue(completedManager.pendingRequests.isEmpty)
        XCTAssertTrue(inFlightManager.pendingRequests.isEmpty)
    }

    func testPaymentRequestDisplayOnlyShowsMovementAfterPaymentProof() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)

        XCTAssertNil(PaymentRequestDisplay.paymentDirection(for: request))
        XCTAssertEqual(
            PaymentRequestDisplay.statusKey(for: request, isActionable: true),
            "wallet__payment_request_waiting"
        )
        XCTAssertEqual(
            PaymentRequestDisplay.statusKey(for: request, isActionable: false),
            "wallet__payment_request_status_unavailable"
        )

        let paidRequest = request.updatingLifecycleState(.proofSubmitted, paymentProofKind: .onchain)
        XCTAssertEqual(PaymentRequestDisplay.paymentDirection(for: paidRequest), .incoming)
        XCTAssertEqual(
            PaymentRequestDisplay.statusKey(for: paidRequest, isActionable: false),
            "wallet__payment_request_status_paid"
        )
    }

    func testUnaffordableRequestUsesRequestedAmountAndStopsAutomaticPresentation() async throws {
        let clock = PaymentRequestTestClock(Date())
        let onchainMethod = PublicPaykitService.MethodId.onchainMethodId(network: Env.network, scriptType: .p2wpkh)
        let sdk = try PaymentRequestSdkMock(records: [
            paymentRequestRecord(amount: "0.00001", endpoints: [onchainMethod.rawValue]),
        ])
        let manager = paymentRequestManager(sdk: sdk, clock: clock)
        await manager.refresh()
        let request = try XCTUnwrap(manager.requestsForPresentation().first)
        let app = AppViewModel(
            sheetViewModel: SheetViewModel(),
            navigationViewModel: NavigationViewModel(),
            scanPaymentOperations: ScanPaymentOperations(
                state: {
                    ScanPaymentState(
                        isNodeRunning: true,
                        spendableOnchainBalanceSats: 100,
                        totalLightningBalanceSats: 0,
                        hasChannels: false,
                        hasUsableChannels: false
                    )
                },
                canSendLightning: { _ in false }
            )
        )
        let context = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request)
        XCTAssertTrue(app.claimContactPaymentContext(context))

        await sdk.pauseNextPaymentRequestList()
        let refresh = Task { await manager.refresh() }
        try await waitUntil { await sdk.paymentRequestListIsPaused() }

        try await app.handleScannedData(
            "bitcoin:bcrt1q6rhpng9evdsfnn833a4f4vej0asu6dk5srld6x",
            claimedContactPaymentContext: context
        )

        XCTAssertNil(app.scannedOnchainInvoice)
        XCTAssertNil(app.scannedLightningInvoice)
        XCTAssertTrue(app.didRejectScannedPaymentForInsufficientBalance)

        var didResetWalletSendState = false
        PaykitPaymentRequestPresentationCoordinator.handleUnavailablePaymentRoute(
            request,
            app: app,
            manager: manager,
            resetWalletSendState: { didResetWalletSendState = true }
        )
        clock.advance(by: 2)

        XCTAssertTrue(didResetWalletSendState)
        XCTAssertNil(app.contactPaymentContext)
        XCTAssertEqual(manager.pendingRequests, [request])
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)

        await sdk.resumePaymentRequestList()
        _ = await refresh.value
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)
        XCTAssertTrue(manager.requestPresentation(request))
        XCTAssertEqual(manager.requestsForPresentation(), [request])
    }

    func testAmountMismatchIsVisibleAndStopsAutomaticPresentationUntilExplicitRetry() async throws {
        for userRequested in [false, true] {
            let clock = PaymentRequestTestClock(Date())
            let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
            let manager = paymentRequestManager(sdk: sdk, clock: clock)
            await manager.refresh()
            let request = try XCTUnwrap(manager.pendingRequests.first)
            if userRequested {
                XCTAssertTrue(manager.requestPresentation(request))
            }
            var shownErrors: [PaykitPaymentRequestError] = []

            XCTAssertTrue(PaykitPaymentRequestPresentationCoordinator.handleAmountMismatch(
                PaykitPaymentRequestError.amountMismatch,
                request: request,
                manager: manager,
                showError: {
                    if let error = $0 as? PaykitPaymentRequestError {
                        shownErrors.append(error)
                    }
                }
            ))

            XCTAssertEqual(shownErrors, [.amountMismatch])
            clock.advance(by: 300)
            await manager.refresh()
            XCTAssertEqual(manager.pendingRequests, [request])
            XCTAssertTrue(manager.requestsForPresentation().isEmpty)
            XCTAssertTrue(manager.requestPresentation(request))
            XCTAssertEqual(manager.requestsForPresentation(), [request])
        }
    }

    func testTransientPresentationErrorRemainsRetryableWithoutMismatchToast() async throws {
        let clock = PaymentRequestTestClock(Date())
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk, clock: clock)
        await manager.refresh()
        let request = try XCTUnwrap(manager.requestsForPresentation().first)

        XCTAssertFalse(PaykitPaymentRequestPresentationCoordinator.handleAmountMismatch(
            PaykitPaymentRequestError.requestUnavailable,
            request: request,
            manager: manager,
            showError: { _ in XCTFail("Transient errors must not show a mismatch toast") }
        ))
        manager.deferPresentation(request)
        clock.advance(by: 2)
        XCTAssertEqual(manager.requestsForPresentation(), [request])
    }

    func testPresentationRetryUsesElapsedTimeAcrossWallClockChanges() async throws {
        for shift in [TimeInterval(-30 * 86400), TimeInterval(30 * 86400)] {
            let clock = PaymentRequestTestClock(Date())
            let manager = try paymentRequestManager(sdk: PaymentRequestSdkMock(records: [paymentRequestRecord()]), clock: clock)
            await manager.refresh()
            let request = try XCTUnwrap(manager.requestsForPresentation().first)
            manager.deferPresentation(request)

            clock.shiftWallClock(by: shift)
            XCTAssertTrue(manager.requestsForPresentation().isEmpty)
            clock.advance(by: 2)
            XCTAssertEqual(manager.requestsForPresentation(), [request])
        }
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
            XCTAssertTrue(manager.isWaitingForPresentationRetry(request))
            XCTAssertTrue(manager.requestsForPresentation().isEmpty)
            clock.advance(by: 2)
            XCTAssertEqual(manager.requestsForPresentation(), [request])
        }

        XCTAssertEqual(manager.deferPresentation(request), .requestedPresentationEnded)
        XCTAssertFalse(manager.isWaitingForPresentationRetry(request))

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

    func testPresentationDispatcherSurfacesExpirationAndRetryExhaustionToasts() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = PaymentRequestTestClock(now)
        let expiredSdk = try PaymentRequestSdkMock(records: [
            paymentRequestRecord(id: "expired-request", expiresAt: timestamp(now.addingTimeInterval(60))),
        ])
        let expiredManager = paymentRequestManager(sdk: expiredSdk, clock: clock)
        await expiredManager.refresh()
        let expiredRequest = try XCTUnwrap(expiredManager.pendingRequests.first)
        XCTAssertTrue(expiredManager.requestPresentation(expiredRequest))

        let previousExpirationState = IncomingPaykitPaymentRequestPresentationState(expiredManager)
        clock.advance(by: 60)
        expiredManager.reconcileExpiredRequests()
        let expiredDispatches = IncomingPaykitPaymentRequestPresentationDispatcher.handleStateChange(
            from: previousExpirationState,
            to: IncomingPaykitPaymentRequestPresentationState(expiredManager),
            manager: expiredManager
        )

        XCTAssertEqual(
            expiredDispatches,
            [
                .presentFeedback(
                    IncomingPaykitPaymentRequestPresentationFeedback(
                        deferral: .requestExpired(wasRequested: true),
                        fallbackReason: .resolutionFailed
                    ),
                    expiredRequest
                ),
                .presentNext,
            ]
        )
        XCTAssertNil(expiredManager.consumeExpiredRequestedPresentation())

        let retrySdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let retryManager = paymentRequestManager(sdk: retrySdk, clock: clock)
        await retryManager.refresh()
        let retryRequest = try XCTUnwrap(retryManager.pendingRequests.first)
        XCTAssertTrue(retryManager.requestPresentation(retryRequest))

        for _ in 0 ..< 14 {
            XCTAssertEqual(retryManager.deferPresentation(retryRequest), .retryScheduled)
            clock.advance(by: 2)
        }

        let exhaustedFeedback = IncomingPaykitPaymentRequestPresentationDispatcher.feedback(
            deferring: retryRequest,
            reason: .resolutionFailed,
            with: retryManager
        )
        XCTAssertEqual(exhaustedFeedback.diagnosticReason, .resolutionFailed)
        XCTAssertTrue(exhaustedFeedback.isTerminal)
        XCTAssertEqual(exhaustedFeedback.toast?.titleKey, "wallet__payment_request")
        XCTAssertEqual(exhaustedFeedback.toast?.descriptionKey, "wallet__payment_request_unavailable")
        XCTAssertEqual(exhaustedFeedback.toast?.accessibilityIdentifier, "PaymentRequestUnavailableToast")
        XCTAssertNotNil(exhaustedFeedback.diagnosticMessage(for: retryRequest))
    }

    func testPresentationDispatcherLogsFirstAutomaticFailurePerReasonAndLifecycle() async throws {
        let counterparty = "pubky\(String(repeating: "y", count: 52))"
        let record = try paymentRequestRecord(counterparty: counterparty)
        let sdk = PaymentRequestSdkMock(records: [record])
        let clock = PaymentRequestTestClock(Date())
        let manager = paymentRequestManager(sdk: sdk, clock: clock)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)

        let firstFeedback = IncomingPaykitPaymentRequestPresentationDispatcher.feedback(
            deferring: request,
            reason: .noSupportedEndpoint,
            with: manager
        )
        clock.advance(by: 2)
        let repeatedFeedback = IncomingPaykitPaymentRequestPresentationDispatcher.feedback(
            deferring: request,
            reason: .noSupportedEndpoint,
            with: manager
        )
        clock.advance(by: 2)
        let changedReasonFeedback = IncomingPaykitPaymentRequestPresentationDispatcher.feedback(
            deferring: request,
            reason: .invalidPaymentTarget,
            with: manager
        )

        let firstMessage = try XCTUnwrap(firstFeedback.diagnosticMessage(for: request))
        XCTAssertFalse(firstFeedback.isTerminal)
        XCTAssertNil(firstFeedback.toast)
        XCTAssertEqual(
            firstMessage,
            "Rejected incoming Paykit payment request presentation: category=resolution reason=no_supported_endpoint " +
                "counterparty=\(PaykitPaymentRequestDiagnostics.redactedCounterparty(counterparty))"
        )
        XCTAssertFalse(firstMessage.contains(counterparty))
        XCTAssertNil(repeatedFeedback.diagnosticMessage(for: request))
        XCTAssertEqual(
            changedReasonFeedback.diagnosticMessage(for: request),
            "Rejected incoming Paykit payment request presentation: category=presentation reason=invalid_payment_target " +
                "counterparty=\(PaykitPaymentRequestDiagnostics.redactedCounterparty(counterparty))"
        )

        await sdk.setRecords([])
        await manager.refresh()
        await sdk.setRecords([record])
        await manager.refresh()
        let reappearedRequest = try XCTUnwrap(manager.pendingRequests.first)
        let reappearedFeedback = IncomingPaykitPaymentRequestPresentationDispatcher.feedback(
            deferring: reappearedRequest,
            reason: .noSupportedEndpoint,
            with: manager
        )

        XCTAssertNotNil(reappearedFeedback.diagnosticMessage(for: reappearedRequest))
    }

    func testPresentationDispatcherAdvancesQueueAfterRequestedExpiration() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = PaymentRequestTestClock(now)
        let sdk = try PaymentRequestSdkMock(records: [
            paymentRequestRecord(id: "request-a", expiresAt: timestamp(now.addingTimeInterval(1))),
            paymentRequestRecord(
                id: "request-b",
                counterparty: "pubkypayee-b",
                expiresAt: timestamp(now.addingTimeInterval(60))
            ),
        ])
        let manager = paymentRequestManager(sdk: sdk, clock: clock)
        await manager.refresh()
        let requestA = try XCTUnwrap(manager.pendingRequests.first { $0.paymentRequestId == "request-a" })
        let requestB = try XCTUnwrap(manager.pendingRequests.first { $0.paymentRequestId == "request-b" })
        XCTAssertTrue(manager.requestPresentation(requestA))
        XCTAssertEqual(manager.deferPresentation(requestA), .retryScheduled)
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)

        let previous = IncomingPaykitPaymentRequestPresentationState(manager)
        clock.advance(by: 1)
        manager.reconcileExpiredRequests()

        XCTAssertNil(manager.requestedPresentationId)
        XCTAssertEqual(manager.requestsForPresentation(), [requestB])

        let dispatches = IncomingPaykitPaymentRequestPresentationDispatcher.handleStateChange(
            from: previous,
            to: IncomingPaykitPaymentRequestPresentationState(manager),
            manager: manager
        )
        XCTAssertEqual(
            dispatches,
            [
                .presentFeedback(
                    IncomingPaykitPaymentRequestPresentationFeedback(
                        deferral: .requestExpired(wasRequested: true),
                        fallbackReason: .resolutionFailed
                    ),
                    requestA
                ),
                .presentNext,
            ]
        )
        XCTAssertNil(manager.consumeExpiredRequestedPresentation())
    }

    func testPendingRequestArrivalDispatchesPresentationBeforeRefreshFinishes() async throws {
        let sdk = PaymentRequestSdkMock(records: [])
        let notificationCenter = PaykitSubscriptionNotificationCenterMock()
        let manager = paymentRequestManager(
            sdk: sdk,
            subscriptionNotificationScheduler: PaykitSubscriptionNotificationScheduler(center: notificationCenter)
        )
        await manager.refresh()
        let previous = IncomingPaykitPaymentRequestPresentationState(manager)
        try await sdk.setRecords([paymentRequestRecord()])
        await notificationCenter.pauseNextPendingRequests()
        let refreshTask = Task { await manager.refresh() }
        try await waitUntil { await notificationCenter.isPendingRequestsPaused }

        let current = IncomingPaykitPaymentRequestPresentationState(manager)
        let request = try XCTUnwrap(manager.pendingRequests.first)
        let dispatches = IncomingPaykitPaymentRequestPresentationDispatcher.handleStateChange(
            from: previous,
            to: current,
            manager: manager
        )
        XCTAssertEqual(dispatches, [.presentNext])
        XCTAssertEqual(manager.requestsForPresentation(), [request])
        XCTAssertTrue(IncomingPaykitPaymentRequestPresentationDispatcher.handleStateChange(
            from: current,
            to: IncomingPaykitPaymentRequestPresentationState(manager),
            manager: manager
        ).isEmpty)

        await notificationCenter.resumePendingRequests()
        _ = await refreshTask.value
    }

    func testRefreshPreservesUnavailableOutcomeForRequestedPresentation() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
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

        let previous = IncomingPaykitPaymentRequestPresentationState(manager)
        await sdk.setRecords([])
        await manager.refresh()

        XCTAssertFalse(manager.isCurrentPresentation(request))
        XCTAssertNil(manager.requestedPresentationId)
        XCTAssertTrue(manager.pendingRequests.isEmpty)
        XCTAssertEqual(manager.requestedPresentationUnavailableTrigger, 1)

        let dispatches = IncomingPaykitPaymentRequestPresentationDispatcher.handleStateChange(
            from: previous,
            to: IncomingPaykitPaymentRequestPresentationState(manager),
            manager: manager
        )
        XCTAssertEqual(
            dispatches,
            [
                .presentFeedback(
                    IncomingPaykitPaymentRequestPresentationFeedback(
                        deferral: .requestedPresentationEnded,
                        fallbackReason: .resolutionFailed
                    ),
                    request
                ),
            ]
        )
        XCTAssertNil(manager.consumeUnavailableRequestedPresentation())

        continuation?.resume()
        _ = await presentationTask.value
    }

    func testRefreshRecordsUnavailableBeforeSuspendedNotificationSynchronization() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = PaymentRequestTestClock(now)
        let sdk = try PaymentRequestSdkMock(records: [
            paymentRequestRecord(expiresAt: timestamp(now.addingTimeInterval(60))),
        ])
        let notificationCenter = PaykitSubscriptionNotificationCenterMock()
        let notificationScheduler = PaykitSubscriptionNotificationScheduler(center: notificationCenter)
        let manager = paymentRequestManager(
            sdk: sdk,
            clock: clock,
            subscriptionNotificationScheduler: notificationScheduler
        )
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        XCTAssertTrue(manager.requestPresentation(request))

        let previous = IncomingPaykitPaymentRequestPresentationState(manager)
        await sdk.setRecords([])
        await notificationCenter.pauseNextPendingRequests()
        let refreshTask = Task { await manager.refresh() }
        try await waitUntil { await notificationCenter.isPendingRequestsPaused }

        XCTAssertTrue(manager.pendingRequests.isEmpty)
        XCTAssertNil(manager.requestedPresentationId)
        XCTAssertEqual(manager.requestedPresentationUnavailableTrigger, 1)

        clock.advance(by: 60)
        manager.reconcileExpiredRequests()

        XCTAssertEqual(manager.requestedPresentationExpirationTrigger, 0)
        await notificationCenter.resumePendingRequests()
        _ = await refreshTask.value

        let dispatches = IncomingPaykitPaymentRequestPresentationDispatcher.handleStateChange(
            from: previous,
            to: IncomingPaykitPaymentRequestPresentationState(manager),
            manager: manager
        )
        XCTAssertEqual(
            dispatches,
            [
                .presentFeedback(
                    IncomingPaykitPaymentRequestPresentationFeedback(
                        deferral: .requestedPresentationEnded,
                        fallbackReason: .resolutionFailed
                    ),
                    request
                ),
            ]
        )
        XCTAssertNil(manager.consumeUnavailableRequestedPresentation())
    }

    func testRetryDuringSuspendedNotificationSynchronizationStaysPresented() async throws {
        let record = try paymentRequestRecord(state: .accepted)
        let sdk = PaymentRequestSdkMock(records: [record])
        let notificationCenter = PaykitSubscriptionNotificationCenterMock()
        let notificationScheduler = PaykitSubscriptionNotificationScheduler(center: notificationCenter)
        let manager = paymentRequestManager(
            sdk: sdk,
            subscriptionNotificationScheduler: notificationScheduler,
            acceptedRecords: [record]
        )
        await manager.refresh()
        let acceptedRequest = try XCTUnwrap(manager.historyRequests.first)

        await notificationCenter.pauseNextPendingRequests()
        let refreshTask = Task { await manager.refresh() }
        try await waitUntil { await notificationCenter.isPendingRequestsPaused }

        let retryRequest = await manager.paymentRequestForRetry(acceptedRequest.id)
        let retriedRequest = try XCTUnwrap(retryRequest)
        XCTAssertTrue(manager.markPresentedIfPending(retriedRequest))
        XCTAssertEqual(manager.pendingRequests, [retriedRequest])
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)

        await notificationCenter.resumePendingRequests()
        _ = await refreshTask.value

        XCTAssertEqual(manager.pendingRequests, [retriedRequest])
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)
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

    func testHardwareFailureCleanupReleasesConsumptionAfterPrivateServiceRestart() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.removeObject(forKey: PrivatePaykitService.cacheStateKey)
        let counterparty = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord(counterparty: counterparty, endpoints: [endpoint])])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        let privateContext = PrivatePaykitPaymentContext(paymentAppsByEndpoint: [endpoint: "bitkit"], paymentListVersion: 7)
        let context = ContactPaymentContext(publicKey: counterparty, privatePaymentContext: privateContext, incomingPaymentRequest: request)
        let app = AppViewModel()
        XCTAssertTrue(app.claimContactPaymentContext(context))
        let privateService = PrivatePaykitService()
        let priorContext = PrivatePaykitPaymentContext(paymentAppsByEndpoint: [endpoint: "bitkit"], paymentListVersion: 6)
        try await privateService.consumePrivatePaymentList(publicKey: counterparty, context: priorContext, attemptId: UUID())
        let store = HardwarePaymentProofMemoryStore()
        let identity = "pubky" + String(repeating: "z", count: 52)
        let walletId = "trezor:original-ios-wallet"
        let proofService = PaykitPaymentProofService(
            sdk: sdk,
            store: store,
            hardwareTransactionLookup: PaymentProofHardwareLookup(result: .failure(NSError(domain: "fixture", code: 1))),
            logInfo: { _ in },
            logWarning: { _ in }
        )
        try await proofService.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
        let previousVersion = await privateService.consumedPaymentListVersion(publicKey: counterparty)
        XCTAssertEqual(previousVersion, 6)
        try await manager.prepareForPayment(request) {
            try await privateService.consumePrivatePaymentList(publicKey: counterparty, context: privateContext, attemptId: context.id)
        }
        let signed = HwFundingSignedTx(
            serializedTx: "02000000000101f7c5a048189164c6b05b07516b5dbb9c826c601d12dc4ed97f0069618b8b7c160100000000fdffffff024179010000000000160014f066a63663b0d464b31a7a88619beae011c3fb7be80300000000000016001483ea855bb508cb08ed9e8cf9152d8927871c19aa02473044022052c5a15ade616af16f314bcc2ae15bf4ef4996e0f2315794e647ba6c955745b602200f3095f4a7deb39a94716c0fd2001a2fbff1861a8ff0c2015739a40a62891c22012102cb13c86b55418d0e3bccf29115394e1fb6a9f209d3f59dc9bbb0805b253464cb724c0300",
            miningFeeSats: 141,
            feeRate: 2,
            totalSpent: request.amountSats + 141
        )
        try await proofService.markOnchainPaymentStarted(
            request,
            address: "bcrt1qhardwarecleanup",
            hardwareWalletId: walletId,
            paymentIdentity: identity,
            signedTx: signed,
            privatePaymentListVersion: privateContext.paymentListVersion,
            previousPrivatePaymentListVersion: previousVersion
        )
        let snapshot = try await proofService.backupSnapshot()
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode([PaykitPaymentStateBackup.Proof].self, from: encoded)
        let restored = try decoded.map { try $0.restored() }
        XCTAssertEqual(restored.first?.privatePaymentListVersion, 7)
        XCTAssertEqual(restored.first?.previousPrivatePaymentListVersion, 6)
        try await store.save(restored)
        // A new private service loads durable consumption but has no in-memory attempt ledger.
        let restartedPrivateService = PrivatePaykitService()
        let consumedBefore = await restartedPrivateService.state.contacts[counterparty]?.consumedPrivatePaymentListVersion
        XCTAssertEqual(consumedBefore, 7)
        await store.failNextSave()
        await SendSheet.cancelHardwareContactPayment(
            context, outcome: .definitePreBroadcastFailure, app: app, manager: manager,
            privatePaykitService: restartedPrivateService, paymentProofService: proofService, hardwareWalletId: walletId, paymentIdentity: identity
        )
        let retainedAfterFailure = try await store.load()
        XCTAssertEqual(retainedAfterFailure, restored, "Failed proof deletion must retain the original receipt for retry")
        await SendSheet.cancelHardwareContactPayment(
            context, outcome: .definitePreBroadcastFailure, app: app, manager: manager,
            privatePaykitService: restartedPrivateService, paymentProofService: proofService, hardwareWalletId: walletId, paymentIdentity: identity
        )
        let remaining = try await store.load()
        XCTAssertTrue(remaining.isEmpty)
        let consumedAfter = await PrivatePaykitService().state.contacts[counterparty]?.consumedPrivatePaymentListVersion
        XCTAssertEqual(consumedAfter, 6,
                       "Cancelling the unsent version must preserve the previously consumed boundary")
        let newerContext = PrivatePaykitPaymentContext(paymentAppsByEndpoint: [endpoint: "bitkit"], paymentListVersion: 8)
        try await restartedPrivateService.consumePrivatePaymentList(publicKey: counterparty, context: newerContext, attemptId: UUID())
        try await restartedPrivateService.releaseUnsentPaymentListVersion(publicKey: counterparty, version: 7)
        let newerVersion = await restartedPrivateService.state.contacts[counterparty]?.consumedPrivatePaymentListVersion
        XCTAssertEqual(newerVersion, 8, "Cleanup of the original receipt cannot release a newer version")
    }

    func testQueuedHardwareExpiryRestoresPreviousConsumptionAfterRestart() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.removeObject(forKey: PrivatePaykitService.cacheStateKey)
        let counterparty = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord(counterparty: counterparty, endpoints: [endpoint])])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        let privateContext = PrivatePaykitPaymentContext(paymentAppsByEndpoint: [endpoint: "bitkit"], paymentListVersion: 7)
        let context = ContactPaymentContext(publicKey: counterparty, privatePaymentContext: privateContext, incomingPaymentRequest: request)
        let app = AppViewModel()
        XCTAssertTrue(app.claimContactPaymentContext(context))
        let privateService = PrivatePaykitService()
        let priorContext = PrivatePaykitPaymentContext(paymentAppsByEndpoint: [endpoint: "bitkit"], paymentListVersion: 6)
        try await privateService.consumePrivatePaymentList(publicKey: counterparty, context: priorContext, attemptId: UUID())
        let store = HardwarePaymentProofMemoryStore()
        let identity = "pubky" + String(repeating: "z", count: 52)
        let walletId = "trezor:original-ios-wallet"
        let proofService = PaykitPaymentProofService(
            sdk: sdk,
            store: store,
            hardwareTransactionLookup: PaymentProofHardwareLookup(result: .failure(NSError(domain: "fixture", code: 1))),
            logInfo: { _ in },
            logWarning: { _ in }
        )
        try await proofService.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
        let previousVersion = await privateService.consumedPaymentListVersion(publicKey: counterparty)
        XCTAssertEqual(previousVersion, 6)
        try await manager.prepareForPayment(request) {
            try await privateService.consumePrivatePaymentList(publicKey: counterparty, context: privateContext, attemptId: context.id)
        }
        let signed = HwFundingSignedTx(
            serializedTx: "02000000000101f7c5a048189164c6b05b07516b5dbb9c826c601d12dc4ed97f0069618b8b7c160100000000fdffffff024179010000000000160014f066a63663b0d464b31a7a88619beae011c3fb7be80300000000000016001483ea855bb508cb08ed9e8cf9152d8927871c19aa02473044022052c5a15ade616af16f314bcc2ae15bf4ef4996e0f2315794e647ba6c955745b602200f3095f4a7deb39a94716c0fd2001a2fbff1861a8ff0c2015739a40a62891c22012102cb13c86b55418d0e3bccf29115394e1fb6a9f209d3f59dc9bbb0805b253464cb724c0300",
            miningFeeSats: 141,
            feeRate: 2,
            totalSpent: request.amountSats + 141
        )
        try await proofService.markOnchainPaymentStarted(
            request,
            address: "bcrt1qhardwarecleanup",
            hardwareWalletId: walletId,
            paymentIdentity: identity,
            signedTx: signed,
            privatePaymentListVersion: privateContext.paymentListVersion,
            previousPrivatePaymentListVersion: previousVersion
        )
        let snapshot = try await proofService.backupSnapshot()
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode([PaykitPaymentStateBackup.Proof].self, from: encoded)
        let restored = try decoded.map { try $0.restored() }
        XCTAssertEqual(restored.first?.privatePaymentListVersion, 7)
        XCTAssertEqual(restored.first?.previousPrivatePaymentListVersion, 6)
        try await store.save(restored)
        // A new private service loads durable consumption but has no in-memory attempt ledger.
        let restartedPrivateService = PrivatePaykitService()
        let consumedBefore = await restartedPrivateService.state.contacts[counterparty]?.consumedPrivatePaymentListVersion
        XCTAssertEqual(consumedBefore, 7)
        await store.failNextSave()
        let failed = await proofService.clearHardwareCandidateBeforeDispatch(
            requestId: request.id, paymentIdentity: identity, walletId: walletId,
            serializedTx: signed.serializedTx, privatePaykitService: restartedPrivateService
        )
        XCTAssertFalse(failed)
        let retainedAfterFailure = try await store.load()
        XCTAssertEqual(retainedAfterFailure, restored)
        let retainedVersion = await PrivatePaykitService().state.contacts[counterparty]?.consumedPrivatePaymentListVersion
        XCTAssertEqual(retainedVersion, 7, "A failed deletion must retain consumption with the signed receipt")
        // A process can restart after the version release but before proof removal finishes.
        try await restartedPrivateService.releaseUnsentPaymentListVersion(publicKey: counterparty, version: 7, previousVersion: 6)
        let recoveredPrivateService = PrivatePaykitService()
        let recoveredReceipt = try await proofService.retainedHardwareOnchainPayment(
            requestId: request.id, paymentIdentity: identity, walletId: walletId,
            address: "bcrt1qhardwarecleanup", amountSats: request.amountSats,
            privatePaykitService: recoveredPrivateService
        )
        XCTAssertEqual(recoveredReceipt?.signedTx, signed)
        let recoveredVersion = await PrivatePaykitService().state.contacts[counterparty]?.consumedPrivatePaymentListVersion
        XCTAssertEqual(recoveredVersion, 7, "Restored receipt must consume its original version before retry")
        let cleared = await proofService.clearHardwareCandidateBeforeDispatch(
            requestId: request.id, paymentIdentity: identity, walletId: walletId,
            serializedTx: signed.serializedTx, privatePaykitService: recoveredPrivateService
        )
        XCTAssertTrue(cleared)
        let remaining = try await store.load()
        XCTAssertTrue(remaining.isEmpty)
        let consumedAfter = await PrivatePaykitService().state.contacts[counterparty]?.consumedPrivatePaymentListVersion
        XCTAssertEqual(consumedAfter, 6,
                       "Cancelling the unsent version must preserve the previously consumed boundary")
        let newerContext = PrivatePaykitPaymentContext(paymentAppsByEndpoint: [endpoint: "bitkit"], paymentListVersion: 8)
        try await restartedPrivateService.consumePrivatePaymentList(publicKey: counterparty, context: newerContext, attemptId: UUID())
        try await restartedPrivateService.releaseUnsentPaymentListVersion(publicKey: counterparty, version: 7)
        let newerVersion = await restartedPrivateService.state.contacts[counterparty]?.consumedPrivatePaymentListVersion
        XCTAssertEqual(newerVersion, 8, "Cleanup of the original receipt cannot release a newer version")
    }


    func testHardwareFailureCleanupPreservesConsumptionProofAndRetryOwnership() async throws {
        snapshotAppDefaultsDomain()
        let counterparty = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
        let endpoint = PublicPaykitService.MethodId.regtestOnchainP2wpkh.rawValue
        let cases: [(outcome: PrivatePaymentListSendOutcome, started: Bool, ownsContext: Bool, paid: Bool)] = [
            (.definitePreBroadcastFailure, true, true, false),
            (.definitePreBroadcastFailure, false, true, false),
            (.uncertain, true, true, false),
            (.definitePreBroadcastFailure, true, false, false),
            (.definitePreBroadcastFailure, true, true, true),
        ]

        for testCase in cases {
            UserDefaults.standard.removeObject(forKey: PrivatePaykitService.cacheStateKey)
            let privateService = PrivatePaykitService()
            let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord(counterparty: counterparty, endpoints: [endpoint])])
            let manager = paymentRequestManager(sdk: sdk)
            await manager.refresh()
            let request = try XCTUnwrap(manager.pendingRequests.first)
            let app = AppViewModel()
            let privateContext = PrivatePaykitPaymentContext(paymentAppsByEndpoint: [endpoint: "bitkit"], paymentListVersion: 7)
            let context = ContactPaymentContext(
                publicKey: counterparty,
                privatePaymentContext: privateContext,
                incomingPaymentRequest: request,
                isInitialSubscriptionPayment: true
            )
            XCTAssertTrue(app.claimContactPaymentContext(context))
            let proofStore = HardwarePaymentProofMemoryStore()
            let proofService = PaykitPaymentProofService(
                sdk: sdk,
                store: proofStore,
                logInfo: { _ in },
                logWarning: { _ in }
            )
            try await proofService.prepare(request: request, paymentAppId: "bitkit", paymentEndpointIdentifier: endpoint, kind: .onchain)
            try await manager.prepareForPayment(request) {
                try await privateService.consumePrivatePaymentList(publicKey: counterparty, context: privateContext, attemptId: context.id)
            }
            if testCase.started {
                try await proofService.markOnchainPaymentStarted(request, address: "bcrt1qhardwarecleanup")
            }
            let preparedProofs = try await proofStore.load()
            XCTAssertEqual(preparedProofs.count, 1)
            let acceptedRecord = try paymentRequestRecord(
                counterparty: counterparty,
                state: testCase.paid ? .proofSubmitted : .accepted,
                endpoints: [endpoint]
            )
            try await sdk.setRecords([acceptedRecord])
            if !testCase.paid {
                await sdk.setLinkedPeersError(.linkedPeers)
                do {
                    try await manager.ensurePaymentAllowed(request)
                    XCTFail("Expected final authorization to fail")
                } catch {
                    XCTAssertEqual(error as? PaymentRequestSdkMockError, .linkedPeers)
                }
                await sdk.setLinkedPeersError(nil)
                try await manager.ensurePaymentAllowed(request)
            }
            if !testCase.ownsContext {
                app.contactPaymentContext = ContactPaymentContext(publicKey: counterparty)
            }
            let contextBeforeCleanup = app.contactPaymentContext

            await SendSheet.cancelHardwareContactPayment(
                context,
                outcome: testCase.outcome,
                app: app,
                manager: manager,
                privatePaykitService: privateService,
                paymentProofService: proofService
            )

            let persistedVersion = await PrivatePaykitService().state.contacts[counterparty]?
                .consumedPrivatePaymentListVersion
            let remainingProofs = try await proofStore.load()
            if testCase.outcome == .uncertain {
                XCTAssertEqual(persistedVersion, privateContext.paymentListVersion)
                XCTAssertEqual(remainingProofs, preparedProofs)
                XCTAssertEqual(app.contactPaymentContext, contextBeforeCleanup)
                do {
                    try await privateService.consumePrivatePaymentList(publicKey: counterparty, context: privateContext, attemptId: UUID())
                    XCTFail("Uncertain sends must keep the private list consumed")
                } catch PrivatePaykitError.paymentListAlreadyConsumed {}
                let restartedProofService = PaykitPaymentProofService(sdk: sdk, store: proofStore, logInfo: { _ in }, logWarning: { _ in })
                do {
                    try await restartedProofService.prepare(
                        request: request,
                        paymentAppId: "bitkit",
                        paymentEndpointIdentifier: endpoint,
                        kind: .onchain
                    )
                    XCTFail("An uncertain started proof must prevent a new preparation")
                } catch PaykitPaymentRequestError.operationInProgress {}
            } else {
                XCTAssertNil(persistedVersion)
                XCTAssertTrue(remainingProofs.isEmpty)
                if testCase.ownsContext, !testCase.paid {
                    let retriedContext = try XCTUnwrap(app.contactPaymentContext)
                    let retriedRequest = try XCTUnwrap(retriedContext.incomingPaymentRequest)
                    XCTAssertEqual(retriedContext.id, context.id)
                    XCTAssertEqual(retriedContext.publicKey, context.publicKey)
                    XCTAssertEqual(retriedContext.privatePaymentContext, context.privatePaymentContext)
                    XCTAssertEqual(retriedContext.isInitialSubscriptionPayment, context.isInitialSubscriptionPayment)
                    XCTAssertEqual(retriedRequest.lifecycleState, .accepted)
                    try await proofService.prepare(
                        request: retriedRequest,
                        paymentAppId: "bitkit",
                        paymentEndpointIdentifier: endpoint,
                        kind: .onchain
                    )
                    try await manager.prepareForPayment(retriedRequest) {
                        try await privateService.consumePrivatePaymentList(
                            publicKey: counterparty, context: privateContext, attemptId: retriedContext.id
                        )
                    }
                    XCTAssertTrue(manager.isApprovedForPayment(retriedRequest))
                } else {
                    XCTAssertEqual(app.contactPaymentContext, contextBeforeCleanup)
                }
            }
            let snapshot = await sdk.snapshot()
            XCTAssertEqual(snapshot.acceptedRequests.map(\.paymentRequestId), [request.paymentRequestId])
        }
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

    func testInterruptedPreparationRemainsImmediatelyPresentableAfterForegroundOrUnlock() async throws {
        for interruption in [(isSceneActive: false, isUnlocked: true), (isSceneActive: true, isUnlocked: false)] {
            for userRequested in [false, true] {
                let clock = PaymentRequestTestClock(Date())
                let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
                let manager = paymentRequestManager(sdk: sdk, clock: clock)
                await manager.refresh()
                let request = try XCTUnwrap(manager.requestsForPresentation().first)
                if userRequested {
                    XCTAssertTrue(manager.requestPresentation(request))
                }
                let sheets = SheetViewModel()
                let app = AppViewModel(sheetViewModel: sheets, navigationViewModel: NavigationViewModel())
                let context = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request)
                let invoice = OnChainInvoice(address: "bcrt1qexample", amountSatoshis: 0, label: nil, message: nil, params: nil)
                var isSceneActive = true
                var isUnlocked = true
                var walletResetCount = 0
                var continuation: CheckedContinuation<Void, Never>?

                let preparation = Task {
                    await manager.presentRequests { _ in
                        XCTAssertTrue(app.claimContactPaymentContext(context))
                        await withCheckedContinuation { continuation = $0 }
                        app.scannedOnchainInvoice = invoice
                        if PaykitPaymentRequestPresentationCoordinator.canPresentPreparedRequest(
                            isSceneActive: isSceneActive,
                            isUnlocked: isUnlocked,
                            context: context,
                            app: app,
                            resetWalletSendState: { walletResetCount += 1 }
                        ) {
                            sheets.showSheet(.send, data: SendConfig(view: .confirm))
                        }
                    }
                }
                try await waitUntil { continuation != nil }
                isSceneActive = interruption.isSceneActive
                isUnlocked = interruption.isUnlocked
                continuation?.resume()
                let interrupted = await preparation.value
                XCTAssertTrue(interrupted)

                XCTAssertNil(sheets.activeSheetConfiguration)
                XCTAssertNil(app.contactPaymentContext)
                XCTAssertFalse(app.hasSendPaymentTarget)
                XCTAssertEqual(walletResetCount, 1)
                XCTAssertEqual(manager.pendingRequests, [request])
                XCTAssertEqual(manager.requestsForPresentation(), [request])
                XCTAssertEqual(manager.requestedPresentationId, userRequested ? request.id : nil)

                isSceneActive = true
                isUnlocked = true
                let presented = await manager.presentRequests { requests in
                    XCTAssertEqual(requests, [request])
                    XCTAssertTrue(app.claimContactPaymentContext(context))
                    app.scannedOnchainInvoice = invoice
                    if PaykitPaymentRequestPresentationCoordinator.canPresentPreparedRequest(
                        isSceneActive: isSceneActive,
                        isUnlocked: isUnlocked,
                        context: context,
                        app: app,
                        resetWalletSendState: { walletResetCount += 1 }
                    ) {
                        sheets.showSheet(.send, data: SendConfig(view: .confirm))
                    }
                }
                XCTAssertTrue(presented)
                XCTAssertEqual(sheets.activeSheetConfiguration?.id, .send)
                XCTAssertTrue(app.ownsContactPaymentContext(context))
                XCTAssertEqual(app.scannedOnchainInvoice?.address, invoice.address)
                XCTAssertEqual(walletResetCount, 1)
            }
        }
    }

    func testInterruptedPreparationPreservesReplacementPaymentContext() {
        let app = AppViewModel()
        let interruptedContext = ContactPaymentContext(publicKey: "pubkyold")
        let replacementContext = ContactPaymentContext(publicKey: "pubkynew")
        XCTAssertTrue(app.claimContactPaymentContext(interruptedContext))
        app.resetSendState()
        XCTAssertTrue(app.claimContactPaymentContext(replacementContext))
        app.scannedOnchainInvoice = OnChainInvoice(
            address: "bcrt1qreplacement", amountSatoshis: 0, label: nil, message: nil, params: nil
        )

        XCTAssertFalse(PaykitPaymentRequestPresentationCoordinator.canPresentPreparedRequest(
            isSceneActive: false,
            isUnlocked: false,
            context: interruptedContext,
            app: app,
            resetWalletSendState: { XCTFail("A replaced context must not reset wallet send state") }
        ))
        XCTAssertTrue(app.ownsContactPaymentContext(replacementContext))
        XCTAssertEqual(app.scannedOnchainInvoice?.address, "bcrt1qreplacement")
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

    func testPreparingSheetRequiresCurrentPresentationSessionAndContext() async throws {
        let expiresAt = Date().addingTimeInterval(60)
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord(
            expiresAt: PaykitSubscriptionTimestamp.string(from: expiresAt)
        )])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let profile = PubkyProfileManager()
        profile.publicKey = "pubky\(String(repeating: "z", count: 52))"
        let session = try XCTUnwrap(profile.currentSession)

        await manager.presentRequests { requests in
            guard let request = requests.first else {
                XCTFail("Expected an incoming payment request")
                return
            }
            let preparation = IncomingPaykitPaymentRequestPreparation(request: request, session: session)
            XCTAssertEqual(preparation.visibleRequest(manager: manager, session: session, paymentContext: nil), request)
            XCTAssertNil(preparation.visibleRequest(manager: manager, session: nil, paymentContext: nil))
            profile.publicKey = "pubky\(String(repeating: "y", count: 52))"
            XCTAssertNil(preparation.visibleRequest(manager: manager, session: profile.currentSession, paymentContext: nil))
            XCTAssertNil(preparation.visibleRequest(manager: manager, session: session, paymentContext: nil, now: expiresAt))

            let context = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request)
            preparation.paymentContext = context
            XCTAssertEqual(preparation.visibleRequest(manager: manager, session: session, paymentContext: context), request)
            XCTAssertNil(preparation.visibleRequest(manager: manager, session: session, paymentContext: nil))
            XCTAssertNil(preparation.visibleRequest(
                manager: manager,
                session: session,
                paymentContext: ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request)
            ))

            XCTAssertTrue(manager.isCurrentPresentation(request))
            XCTAssertEqual(manager.deferPresentation(request), .retryScheduled)
            XCTAssertEqual(preparation.visibleRequest(manager: manager, session: session, paymentContext: context), request)
            manager.clear()
            XCTAssertFalse(manager.isCurrentPresentation(request))
            XCTAssertNil(preparation.visibleRequest(manager: manager, session: session, paymentContext: context))
        }
    }

    func testPreparingSheetClearsWhileCanceledPreparationIsStillSuspended() async throws {
        for manuallyRequested in [false, true] {
            let manager = try paymentRequestManager(sdk: PaymentRequestSdkMock(records: [paymentRequestRecord(
                metadata: #"{"note":"Dinner"}"#
            )]))
            await manager.refresh()
            let request = try XCTUnwrap(manager.pendingRequests.first)
            if manuallyRequested {
                XCTAssertTrue(manager.requestPresentation(request))
            }
            let profile = PubkyProfileManager()
            profile.publicKey = "pubky\(String(repeating: "z", count: 52))"
            let session = try XCTUnwrap(profile.currentSession)
            let preparation = IncomingPaykitPaymentRequestPreparation(request: request, session: session)
            var continuation: CheckedContinuation<Void, Never>?
            var preparationFinished = false
            let task = Task {
                await manager.presentRequests { requests in
                    XCTAssertEqual(requests, [request])
                    defer { preparation.clear() }
                    do {
                        try await preparation.whilePreparing {
                            await withCheckedContinuation { continuation = $0 }
                        }
                        XCTFail("Canceled preparation must not advance to confirmation")
                    } catch is CancellationError {
                    } catch {
                        XCTFail("Unexpected preparation error: \(error)")
                    }
                    preparationFinished = true
                }
            }
            defer { continuation?.resume() }
            try await waitUntil { continuation != nil }

            let visible = preparation.visibleRequest(manager: manager, session: session, paymentContext: nil)
            XCTAssertEqual(visible, request)
            XCTAssertEqual(visible?.note, "Dinner")
            XCTAssertEqual(manager.requestsForPresentation(), [request])
            XCTAssertFalse(manager.isApprovedForPayment(request))

            task.cancel()
            try await waitUntil { preparation.request == nil }
            XCTAssertFalse(preparationFinished)
            continuation?.resume()
            continuation = nil
            _ = await task.value
            XCTAssertNil(preparation.request)
            XCTAssertEqual(manager.requestsForPresentation(), [request])
        }
    }

    func testCanceledPreparationThrowsBeforeScheduledCleanup() async throws {
        let manager = try paymentRequestManager(sdk: PaymentRequestSdkMock(records: [paymentRequestRecord()]))
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        let preparation = IncomingPaykitPaymentRequestPreparation(request: request, session: nil)
        let task = Task {
            do {
                try await preparation.whilePreparing {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                XCTFail("Canceled work returned before its scheduled UI cleanup")
            } catch is CancellationError {
            } catch {
                XCTFail("Unexpected preparation error: \(error)")
            }
        }
        await task.value
    }

    func testClosingPreparingSheetIgnoresLateCompletionAndLeavesNextRequestAvailable() async throws {
        for manuallyRequested in [false, true] {
            let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord(id: "first"), paymentRequestRecord(id: "second")])
            let store = PaymentRequestPresentationMemoryStore()
            let manager = paymentRequestManager(sdk: sdk, presentationStore: store)
            await manager.refresh()
            let request = try XCTUnwrap(manager.pendingRequests.first { $0.paymentRequestId == "first" })
            let next = try XCTUnwrap(manager.pendingRequests.first { $0.paymentRequestId == "second" })
            if manuallyRequested { XCTAssertTrue(manager.requestPresentation(request)) }
            let profile = PubkyProfileManager()
            profile.publicKey = "pubky\(String(repeating: "z", count: 52))"
            let session = try XCTUnwrap(profile.currentSession)
            let preparation = IncomingPaykitPaymentRequestPreparation(request: request, session: session)
            let sheets = SheetViewModel()
            let app = AppViewModel()
            let identity = try XCTUnwrap(profile.publicKey)
            let context = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request)
            XCTAssertTrue(app.claimContactPaymentContext(context))
            preparation.paymentContext = context
            sheets.showSheet(.send, data: SendConfig(view: .confirm, preparation: preparation, onDismiss: {
                manager.dismissPreparingRequest(request)
                preparation.clear()
            }))
            var continuation: CheckedContinuation<Void, Never>?
            let task = Task {
                await manager.presentRequests { _ in
                    if manuallyRequested {
                        XCTAssertEqual(manager.deferPresentation(request), .retryScheduled)
                    }
                    await withCheckedContinuation { continuation = $0 }
                    XCTAssertFalse(preparation.complete(route: .confirm, manager: manager, session: session, app: app, sheets: sheets))
                }
            }
            try await waitUntil { continuation != nil }
            XCTAssertEqual(preparation.visibleRequest(manager: manager, session: session, paymentContext: context), request)

            if manuallyRequested {
                sheets.hideSheet()
            } else {
                sheets.sendSheetItem = nil
            }
            app.resetSendState()
            XCTAssertEqual(Set(manager.pendingRequests.map(\.id)), [request.id, next.id])
            XCTAssertEqual(manager.requestsForPresentation(), [next])
            XCTAssertNil(manager.requestedPresentationId)
            XCTAssertTrue(try store.load(identity: identity).isEmpty)
            XCTAssertFalse(manager.isApprovedForPayment(request))

            continuation?.resume()
            _ = await task.value
            await manager.presentRequests { XCTAssertEqual($0, [next]) }
            await manager.refresh()
            XCTAssertEqual(manager.requestsForPresentation(), [next])
            XCTAssertTrue(try store.load(identity: identity).isEmpty)

            let restored = paymentRequestManager(sdk: sdk, presentationStore: store)
            await restored.refresh()
            XCTAssertEqual(Set(restored.requestsForPresentation().map(\.id)), [request.id, next.id])
            XCTAssertTrue(manager.requestPresentation(request))
            XCTAssertEqual(manager.requestsForPresentation(), [request])
            await manager.presentRequests { _ in manager.dismissPreparingRequest(request) }
            manager.activate(identity: "pubky\(String(repeating: "y", count: 52))")
            manager.activate(identity: identity)
            await manager.refresh()
            XCTAssertEqual(Set(manager.requestsForPresentation().map(\.id)), [request.id, next.id])
        }
    }

    func testPreparingRequestBecomesReadyInTheSameSendSheetAndPreservesExplicitRetry() async throws {
        let store = PaymentRequestPresentationMemoryStore()
        let clock = PaymentRequestTestClock(Date())
        let manager = try paymentRequestManager(sdk: PaymentRequestSdkMock(records: [paymentRequestRecord()]), clock: clock, presentationStore: store)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        let profile = PubkyProfileManager()
        profile.publicKey = "pubky\(String(repeating: "z", count: 52))"
        let session = try XCTUnwrap(profile.currentSession)
        let preparation = IncomingPaykitPaymentRequestPreparation(request: request, session: session)
        let sheets = SheetViewModel()
        let app = AppViewModel()
        sheets.showSheet(.send, data: SendConfig(view: .confirm, preparation: preparation, onDismiss: {
            if preparation.resolvedRoute == nil, preparation.matchesSession(profile.currentSession), let request = preparation.request {
                manager.dismissPreparingRequest(request)
            }
            preparation.clear()
        }))
        let presentationID = sheets.activeSheetConfiguration?.presentationID
        XCTAssertTrue(sheets.sendSheetItem?.preparation === preparation)
        XCTAssertNil(app.contactPaymentContext)
        XCTAssertFalse(app.hasSendPaymentTarget)

        for _ in 0 ..< 2 {
            await manager.presentRequests { _ in
                XCTAssertEqual(manager.deferPresentation(request), .retryScheduled)
                XCTAssertFalse(manager.isCurrentPresentation(request))
                XCTAssertEqual(preparation.visibleRequest(manager: manager, session: session, paymentContext: nil), request)
            }
            XCTAssertEqual(preparation.visibleRequest(manager: manager, session: session, paymentContext: nil), request)
            XCTAssertEqual(sheets.activeSheetConfiguration?.presentationID, presentationID)
            XCTAssertFalse(manager.isApprovedForPayment(request))
            XCTAssertTrue(try store.load(identity: "pubky\(String(repeating: "z", count: 52))").isEmpty)
            clock.advance(by: 2)
        }

        await manager.presentRequests { _ in
            XCTAssertFalse(preparation.complete(route: .confirm, manager: manager, session: session, app: app, sheets: sheets))
            let context = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request)
            XCTAssertTrue(app.claimContactPaymentContext(context))
            preparation.paymentContext = context
            let otherProfile = PubkyProfileManager()
            otherProfile.publicKey = "pubky\(String(repeating: "y", count: 52))"
            XCTAssertFalse(preparation.complete(route: .confirm, manager: manager, session: otherProfile.currentSession, app: app, sheets: sheets))
            app.scannedOnchainInvoice = OnChainInvoice(
                address: "bcrt1qrequest",
                amountSatoshis: request.amountSats,
                label: nil,
                message: nil,
                params: nil
            )
            XCTAssertTrue(preparation.complete(route: .confirm, manager: manager, session: session, app: app, sheets: sheets))
        }
        XCTAssertEqual(preparation.resolvedRoute, .confirm)
        XCTAssertEqual(sheets.activeSheetConfiguration?.presentationID, presentationID)
        XCTAssertTrue(sheets.sendSheetItem?.preparation === preparation)
        XCTAssertEqual(manager.requestsForPresentation(), [request])
        XCTAssertFalse(manager.isApprovedForPayment(request))
        XCTAssertTrue(try store.load(identity: "pubky\(String(repeating: "z", count: 52))").isEmpty)
        XCTAssertTrue(manager.markPresentedIfPending(request))
        XCTAssertEqual(try store.load(identity: "pubky\(String(repeating: "z", count: 52))"), [request.id])

        app.resetSendState()
        XCTAssertTrue(manager.requestPresentation(request))
        sheets.hideSheet(reason: "Retrying incoming payment request with fresh private payment details")

        XCTAssertNil(preparation.request)
        XCTAssertNil(sheets.activeSheetConfiguration)
        XCTAssertEqual(manager.requestedPresentationId, request.id)
        XCTAssertEqual(manager.requestsForPresentation(), [request])
        XCTAssertFalse(manager.isApprovedForPayment(request))
        XCTAssertEqual(try store.load(identity: "pubky\(String(repeating: "z", count: 52))"), [request.id])
    }

    func testManualPaymentRetainsUnrelatedReminderThroughConfirmationAndRetry() async throws {
        defer { PaykitSubscriptionNotificationTargetStore.clear() }
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let manualRecord = try paymentRequestRecord(id: "manual")
        let reminderRecord = try paymentRequestRecord(
            id: "reminder", counterparty: "pubky\(String(repeating: "y", count: 52))", state: .activeRecurring,
            recurrence: PaymentRequestRecurrence(every: 1, unit: "month", startsAt: timestamp(now), anchor: timestamp(now), endsAt: nil)
        )
        let target = try XCTUnwrap(PaykitSubscriptionNotificationTarget(userInfo: [
            "payer_identity": "pubky\(String(repeating: "z", count: 52))",
            "payment_request_id": reminderRecord.paymentRequestId,
            "counterparty": reminderRecord.counterparty,
            "billing_period_starts_at": PaykitSubscriptionTimestamp.string(from: now),
        ]))
        let sdk = PaymentRequestSdkMock(records: [manualRecord])
        let manager = paymentRequestManager(sdk: sdk, clock: PaymentRequestTestClock(now))
        await manager.refresh(mode: .stored)
        let request = try XCTUnwrap(manager.pendingRequests.first)
        let sheets = SheetViewModel()
        let app = AppViewModel()
        PaykitSubscriptionNotificationTargetStore.save(target)
        XCTAssertTrue(manager.requestPresentation(request))

        await IncomingPaykitPaymentRequestPresentationDispatcher.presentNextItem(
            manager: manager, sheets: sheets, canRetryPreparation: false,
            handleSubscriptionNotification: { XCTFail("A reminder must not block explicit Pay") },
            presentPaymentRequest: {
                XCTAssertEqual(manager.requestsForPresentation(), [request])
                sheets.showSheet(.send, data: SendConfig(view: .confirm))
            }
        )
        XCTAssertEqual(sheets.activeSheetConfiguration?.id, .send)
        XCTAssertEqual(PaykitSubscriptionNotificationTargetStore.load(), target)

        var retriedPreparation = false
        await IncomingPaykitPaymentRequestPresentationDispatcher.presentNextItem(
            manager: manager, sheets: sheets, canRetryPreparation: true,
            handleSubscriptionNotification: { XCTFail("The preparing payment still owns the sheet") },
            presentPaymentRequest: { retriedPreparation = true }
        )
        XCTAssertTrue(retriedPreparation)
        XCTAssertTrue(app.claimContactPaymentContext(ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request)))
        XCTAssertTrue(manager.markPresentedIfPending(request))

        await sdk.setRecords([manualRecord, reminderRecord])
        await manager.refresh(mode: .stored)
        let reminder = try XCTUnwrap(manager.pendingRequests.first(where: target.matches))
        XCTAssertFalse(IncomingPaykitPaymentRequestPresentationDispatcher.canHandleSubscriptionNotification(
            manager: manager,
            app: app,
            sheets: sheets
        ))
        await IncomingPaykitPaymentRequestPresentationDispatcher.presentNextItem(
            manager: manager, sheets: sheets, canRetryPreparation: false,
            handleSubscriptionNotification: { XCTFail("A ready reminder must not replace confirmation") },
            presentPaymentRequest: { XCTFail("Confirmation must retain its payment") }
        )
        XCTAssertEqual(PaykitSubscriptionNotificationTargetStore.load(), target)

        app.resetSendState()
        XCTAssertTrue(manager.requestPresentation(request))
        sheets.hideSheet(reason: "Retrying incoming payment request with fresh private payment details")
        await IncomingPaykitPaymentRequestPresentationDispatcher.presentNextItem(
            manager: manager, sheets: sheets, canRetryPreparation: false,
            handleSubscriptionNotification: { XCTFail("Explicit retry must keep priority over the ready reminder") },
            presentPaymentRequest: {
                XCTAssertEqual(manager.requestsForPresentation(), [request])
                sheets.showSheet(.send, data: SendConfig(view: .confirm, onDismiss: { manager.dismissPreparingRequest(request) }))
            }
        )
        XCTAssertEqual(sheets.activeSheetConfiguration?.id, .send)
        XCTAssertEqual(PaykitSubscriptionNotificationTargetStore.load(), target)

        sheets.hideSheet()
        XCTAssertTrue(IncomingPaykitPaymentRequestPresentationDispatcher.canHandleSubscriptionNotification(
            manager: manager,
            app: app,
            sheets: sheets
        ))
        await IncomingPaykitPaymentRequestPresentationDispatcher.presentNextItem(
            manager: manager, sheets: sheets, canRetryPreparation: false,
            handleSubscriptionNotification: {
                XCTAssertEqual(PaykitSubscriptionNotificationTargetStore.load(), target)
                XCTAssertTrue(manager.requestPresentation(reminder))
                sheets.showSheet(.send, data: SendConfig(view: .confirm))
            },
            presentPaymentRequest: { XCTFail("The reminder handler owns its presentation") }
        )
        XCTAssertEqual(manager.requestedPresentationId, reminder.id)
        XCTAssertNil(PaykitSubscriptionNotificationTargetStore.load())
    }

    func testSubscriptionNotificationWaitsForExplicitSelectionAndActivePaymentOwnership() async throws {
        let manager = try paymentRequestManager(sdk: PaymentRequestSdkMock(records: [paymentRequestRecord()]))
        await manager.refresh(mode: .stored)
        let request = try XCTUnwrap(manager.pendingRequests.first)
        let sheets = SheetViewModel()
        let app = AppViewModel()
        func canHandleNotification() -> Bool {
            IncomingPaykitPaymentRequestPresentationDispatcher.canHandleSubscriptionNotification(manager: manager, app: app, sheets: sheets)
        }
        XCTAssertTrue(canHandleNotification())
        XCTAssertTrue(manager.requestPresentation(request))
        XCTAssertFalse(canHandleNotification())
        manager.dismissPreparingRequest(request)
        XCTAssertTrue(canHandleNotification())

        XCTAssertTrue(app.claimContactPaymentContext(ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request)))
        XCTAssertFalse(canHandleNotification())
        app.resetSendState()
        XCTAssertTrue(canHandleNotification())
        for sheet in [SheetID.send, .scanner] {
            sheets.showSheet(sheet)
            XCTAssertFalse(canHandleNotification())
            await IncomingPaykitPaymentRequestPresentationDispatcher.presentNextItem(
                manager: manager, sheets: sheets, canRetryPreparation: false,
                handleSubscriptionNotification: { XCTFail("The active sheet must retain ownership") },
                presentPaymentRequest: { XCTFail("The active sheet must retain ownership") }
            )
            XCTAssertEqual(sheets.activeSheetConfiguration?.id, sheet)
            sheets.hideSheet()
            XCTAssertTrue(canHandleNotification())
        }
    }

    func testManualPresentationSupersedesInFlightAutomaticPresentation() async throws {
        let first = try paymentRequestRecord(id: "first")
        let second = try paymentRequestRecord(id: "second")
        let manager = paymentRequestManager(sdk: PaymentRequestSdkMock(records: [first, second]))
        await manager.refresh()
        let secondRequest = try XCTUnwrap(manager.pendingRequests.first { $0.paymentRequestId == "second" })
        let profile = PubkyProfileManager()
        profile.publicKey = "pubky\(String(repeating: "z", count: 52))"
        let session = try XCTUnwrap(profile.currentSession)
        var continuation: CheckedContinuation<Void, Never>?
        var automaticPresentationRemainedCurrent = true
        var preparation: IncomingPaykitPaymentRequestPreparation?

        let task = Task {
            await manager.presentRequests { requests in
                guard let automaticRequest = requests.first else {
                    XCTFail("Expected an incoming payment request")
                    return
                }
                preparation = IncomingPaykitPaymentRequestPreparation(request: automaticRequest, session: session)
                await withCheckedContinuation { continuation = $0 }
                automaticPresentationRemainedCurrent = manager.isCurrentPresentation(automaticRequest)
            }
        }
        try await waitUntil { continuation != nil }

        XCTAssertNotNil(preparation?.visibleRequest(manager: manager, session: session, paymentContext: nil))
        XCTAssertTrue(manager.requestPresentation(secondRequest))
        XCTAssertNil(preparation?.visibleRequest(manager: manager, session: session, paymentContext: nil))
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
        try await sdk.setRecords([paymentRequestRecord(state: .accepted)])

        XCTAssertTrue(manager.isApprovedForPayment(request))
        await manager.finishPayment(request)
        XCTAssertFalse(manager.isApprovedForPayment(request))
        XCTAssertEqual(manager.pendingRequests, [request.updatingLifecycleState(.accepted)])
    }

    func testPaidRequestIsNotRequeuedAfterSendFlowFinishes() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)

        try await manager.prepareForPayment(request)
        try await sdk.setRecords([paymentRequestRecord(state: .proofSubmitted)])

        await manager.finishPayment(request)
        XCTAssertFalse(manager.isApprovedForPayment(request))
        XCTAssertTrue(manager.pendingRequests.isEmpty)
    }

    func testPaidRequestIsNotReopenedForRetry() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)

        try await manager.prepareForPayment(request)
        await manager.finishPayment(request)
        try await sdk.setRecords([paymentRequestRecord(state: .proofSubmitted)])

        let retriedRequest = await manager.paymentRequestForRetry(request.id)
        XCTAssertNil(retriedRequest)
        XCTAssertTrue(manager.pendingRequests.isEmpty)
    }

    func testPaidPendingRequestIsNotReopenedForRetry() async throws {
        let record = try paymentRequestRecord(state: .accepted)
        let sdk = PaymentRequestSdkMock(records: [record])
        let manager = paymentRequestManager(sdk: sdk, acceptedRecords: [record])
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)

        try await manager.prepareForPayment(request)
        XCTAssertEqual(manager.pendingRequests, [request])
        try await sdk.setRecords([paymentRequestRecord(state: .proofSubmitted)])

        let retriedRequest = await manager.paymentRequestForRetry(request.id)
        XCTAssertNil(retriedRequest)
    }

    func testUnpaidPendingRequestIsReopenedForRetry() async throws {
        let record = try paymentRequestRecord(state: .accepted)
        let sdk = PaymentRequestSdkMock(records: [record])
        let manager = paymentRequestManager(sdk: sdk, acceptedRecords: [record])
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)

        try await manager.prepareForPayment(request)

        let retriedRequest = await manager.paymentRequestForRetry(request.id)
        XCTAssertEqual(retriedRequest, request)
        XCTAssertFalse(manager.isApprovedForPayment(request))
    }

    func testOnlyAcceptingInstallCanResumeOneTimePayment() async throws {
        var record = try paymentRequestRecord()
        let sdk = PaymentRequestSdkMock(records: [record])
        let store = PaymentRequestPresentationMemoryStore()
        let first = paymentRequestManager(sdk: sdk, acceptanceStore: store)
        let second = paymentRequestManager(sdk: sdk)
        await first.refresh()
        await second.refresh()
        let request = try XCTUnwrap(first.pendingRequests.first)
        let staleRequest = try XCTUnwrap(second.pendingRequests.first)

        try await first.prepareForPayment(request)
        record.state = .accepted
        await sdk.setRecords([record])
        do {
            try await second.prepareForPayment(staleRequest)
            XCTFail("A stale proposal must not bypass SDK acceptance")
        } catch {}
        await second.refresh()
        XCTAssertTrue(second.pendingRequests.isEmpty)
        XCTAssertTrue(second.requestsForPresentation().isEmpty)
        let accepted = try XCTUnwrap(second.historyRequests.first)
        do {
            try await second.ensurePaymentAllowed(accepted)
            XCTFail("Another install's acceptance must not authorize payment")
        } catch {
            XCTAssertEqual(error as? PaykitPaymentRequestError, .requestUnavailable)
        }
        await second.finishPayment(accepted)
        let retry = await second.paymentRequestForRetry(accepted.id)
        XCTAssertNil(retry)

        let restored = paymentRequestManager(sdk: sdk, acceptanceStore: store)
        await restored.refresh()
        let resumable = try XCTUnwrap(restored.pendingRequests.first)
        try await restored.prepareForPayment(resumable)
        XCTAssertTrue(restored.isApprovedForPayment(resumable))
        let acceptedCalls = await sdk.snapshot().acceptedRequests
        XCTAssertEqual(acceptedCalls.count, 1)
    }

    func testAcceptanceCleanupOnlyRemovesConfirmedFinishedRequests() async throws {
        let identity = "pubky\(String(repeating: "z", count: 52))"
        let records = try [
            paymentRequestRecord(id: "paid", state: .proofSubmitted),
            paymentRequestRecord(id: "canceled", state: .canceled),
            paymentRequestRecord(id: "rejected", state: .rejected),
            paymentRequestRecord(id: "retry", state: .accepted, expiresAt: "2020-01-01T00:00:00Z"),
            paymentRequestRecord(id: "recovery", state: .recoveryRequired),
            paymentRequestRecord(id: "conflict", state: .invalidConflict),
        ]
        let missingId = PaykitPaymentRequest.ID(paymentRequestId: "missing", counterparty: "pubkypayee")
        let ids = Set(records.map { PaykitPaymentRequest.ID(paymentRequestId: $0.paymentRequestId, counterparty: $0.counterparty) })
            .union([missingId])
        let store = PaymentRequestPresentationMemoryStore(ids: ids)
        let sdk = PaymentRequestSdkMock(records: [])
        let manager = paymentRequestManager(sdk: sdk, acceptanceStore: store)

        await manager.refresh()
        XCTAssertEqual(try store.load(identity: identity), ids, "An empty refresh must not remove execution ownership")
        await sdk.setRecords(records)
        await manager.refresh()

        let remaining = try store.load(identity: identity)
        XCTAssertEqual(Set(remaining.map(\.paymentRequestId)), ["retry", "recovery", "conflict", "missing"])
        let restarted = paymentRequestManager(sdk: sdk, acceptanceStore: store)
        await restarted.refresh()
        let retry = try XCTUnwrap(restarted.pendingRequests.first)
        XCTAssertEqual(retry.paymentRequestId, "retry")
        try await restarted.prepareForPayment(retry)
        try await restarted.ensurePaymentAllowed(retry)
    }

    func testFailedAcceptanceCleanupRetainsIdsAndRetries() async throws {
        let identity = "pubky\(String(repeating: "z", count: 52))"
        let record = try paymentRequestRecord(state: .proofSubmitted)
        let id = PaykitPaymentRequest.ID(paymentRequestId: record.paymentRequestId, counterparty: record.counterparty)
        let store = PaymentRequestPresentationMemoryStore(ids: [id])
        store.shouldFailSave = true
        let manager = paymentRequestManager(sdk: PaymentRequestSdkMock(records: [record]), acceptanceStore: store)

        await manager.refresh()
        XCTAssertEqual(try store.load(identity: identity), [id])
        XCTAssertTrue(manager.pendingRequests.isEmpty)
        store.shouldFailSave = false
        await manager.refresh()
        XCTAssertTrue(try store.load(identity: identity).isEmpty)
    }

    func testPreparedOneTimePaymentRequiresAcceptedHistory() async throws {
        let cases: [(PaymentRequestRecord?, Bool)] = try [
            (paymentRequestRecord(state: .accepted), true),
            (paymentRequestRecord(state: .canceled), false),
            (paymentRequestRecord(state: .proofSubmitted), false),
            (paymentRequestRecord(state: .rejected), false),
            (nil, false),
            (paymentRequestRecord(state: .recoveryRequired, acceptedEventId: "accepted"), true),
            (paymentRequestRecord(state: .recoveryRequired), false),
            (paymentRequestRecord(state: .recoveryRequired, acceptedEventId: "accepted", canceledEventId: "canceled"), false),
            (paymentRequestRecord(state: .recoveryRequired, acceptedEventId: "accepted", rejectedEventId: "rejected"), false),
            (paymentRequestRecord(state: .recoveryRequired, acceptedEventId: "accepted", paymentProofs: [
                paymentProofRecord(endpoint: "btc-lightning-bolt11", kind: .lightning),
            ]), false),
        ]
        for (record, isAccepted) in cases {
            let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
            let manager = paymentRequestManager(sdk: sdk)
            await manager.refresh()
            let request = try XCTUnwrap(manager.pendingRequests.first)
            try await manager.prepareForPayment(request)
            XCTAssertTrue(manager.isApprovedForPayment(request))
            XCTAssertTrue(manager.pendingRequests.isEmpty)
            await sdk.pauseNextLinkedPeers()

            let authorization = Task { try await manager.ensurePaymentAllowed(request) }
            try await waitUntil { await sdk.linkedPeersIsPaused() }
            let approvalChanged = isAccepted ? nil : expectation(description: "Prepared request history changed")
            XCTAssertTrue(withObservationTracking {
                manager.isApprovedForPayment(request)
            } onChange: {
                approvalChanged?.fulfill()
            })
            let records = record.map { [$0] } ?? []
            await sdk.setRecords(records)
            await manager.refresh(mode: .stored)
            if let approvalChanged {
                await fulfillment(of: [approvalChanged], timeout: 1)
            }
            XCTAssertTrue(manager.pendingRequests.isEmpty)
            XCTAssertEqual(manager.isApprovedForPayment(request), isAccepted, "\(String(describing: record?.state))")
            for root in [SendRoute.confirm, .lnurlPayConfirm] {
                let isAvailable = manager.isApprovedForPayment(request)
                XCTAssertEqual(SendSheet.shouldDismissUnavailableRequest(
                    root: root, path: [], isSubmittingPayment: false, isAvailable: isAvailable
                ), !isAccepted)
                XCTAssertFalse(SendSheet.shouldDismissUnavailableRequest(
                    root: root, path: [], isSubmittingPayment: true, isAvailable: isAvailable
                ))
                let retainedRoutes: [SendRoute] = [
                    .pending(paymentHash: nil, retryRoute: .confirm, paymentRequest: nil),
                    .success(paymentId: "payment"),
                    .failure(SendFailureContext(error: PaykitPaymentRequestError.requestUnavailable, retryRoute: .confirm)),
                    .hardwareSign,
                    .quickpay,
                ]
                for result in retainedRoutes {
                    XCTAssertFalse(SendSheet.shouldDismissUnavailableRequest(
                        root: root, path: [result], isSubmittingPayment: false, isAvailable: isAvailable
                    ))
                    XCTAssertFalse(SendSheet.shouldDismissUnavailableRequest(
                        root: result, path: [], isSubmittingPayment: false, isAvailable: isAvailable
                    ))
                }
            }
            await sdk.resumeLinkedPeers()

            do {
                try await authorization.value
                XCTAssertTrue(isAccepted, "Refreshed one-time history must still be accepted")
            } catch {
                XCTAssertFalse(isAccepted)
                XCTAssertEqual(error as? PaykitPaymentRequestError, .requestUnavailable)
            }
            guard !isAccepted else { continue }

            let peerReads = await sdk.linkedPeersCalls()
            do {
                try await manager.ensurePaymentAllowed(request)
                XCTFail("Unavailable history must not authorize payment")
            } catch {
                XCTAssertEqual(error as? PaykitPaymentRequestError, .requestUnavailable)
            }
            let peerReadsAfterRejection = await sdk.linkedPeersCalls()
            XCTAssertEqual(peerReadsAfterRejection, peerReads)
            do {
                try await manager.prepareForPayment(request) {
                    XCTFail("Unavailable history must not consume another payment destination")
                }
                XCTFail("Unavailable history must not be prepared again")
            } catch {
                XCTAssertEqual(error as? PaykitPaymentRequestError, .requestUnavailable)
            }
        }
    }

    func testIdentitySwitchPreventsExecutionOfPreparedProposal() async throws {
        for switchDuringAuthorization in [false, true] {
            let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
            let manager = paymentRequestManager(sdk: sdk)
            await manager.refresh()
            let proposal = try XCTUnwrap(manager.pendingRequests.first)
            try await manager.prepareForPayment(proposal)
            try await manager.ensurePaymentAllowed(proposal)

            if switchDuringAuthorization {
                await sdk.pauseNextLinkedPeers()
            } else {
                manager.activate(identity: "pubky\(String(repeating: "y", count: 52))")
            }
            let authorization = Task { try await manager.ensurePaymentAllowed(proposal) }
            if switchDuringAuthorization {
                try await waitUntil { await sdk.linkedPeersIsPaused() }
                manager.activate(identity: "pubky\(String(repeating: "y", count: 52))")
                await sdk.resumeLinkedPeers()
            }

            do {
                try await authorization.value
                XCTFail("The previous identity's prepared proposal must not authorize payment")
            } catch {
                XCTAssertEqual(error as? PaykitPaymentRequestError, .requestUnavailable)
            }
            XCTAssertFalse(manager.isApprovedForPayment(proposal))
        }
    }

    func testFailedAcceptancePersistenceDoesNotAuthorizePayment() async throws {
        var record = try paymentRequestRecord()
        let sdk = PaymentRequestSdkMock(records: [record])
        let store = PaymentRequestPresentationMemoryStore()
        store.shouldFailSave = true
        let manager = paymentRequestManager(sdk: sdk, acceptanceStore: store)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)

        do {
            try await manager.prepareForPayment(request)
            XCTFail("Payment must wait for durable local acceptance")
        } catch {
            XCTAssertEqual(error as? PaymentRequestSdkMockError, .process)
        }
        XCTAssertFalse(manager.isApprovedForPayment(request))
        let calls = await sdk.snapshot().acceptedRequests
        XCTAssertTrue(calls.isEmpty, "Do not accept remotely until the local intent is durable")
        record.state = .accepted
        await sdk.setRecords([record])
        await manager.refresh()
        XCTAssertTrue(manager.pendingRequests.isEmpty)
    }

    func testUnreadableAcceptanceStatePreventsActivation() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let store = PaymentRequestPresentationMemoryStore()
        store.shouldFailLoad = true
        let manager = paymentRequestManager(sdk: sdk, acceptanceStore: store)

        await manager.refresh()

        XCTAssertTrue(manager.pendingRequests.isEmpty)
        XCTAssertTrue(manager.requestsForPresentation().isEmpty)
    }

    func testInterruptedAcceptanceCanResumeAfterRefresh() async throws {
        for error in [
            PaykitError.Transport(code: "transport_error", context: "response lost"),
            PaykitError.ConcurrentUpdate(code: "concurrent_update", context: "response read locked"),
            PaykitError.SharedStateBusy(code: "shared_state_busy", context: "response read busy"),
        ] {
            let record = try paymentRequestRecord()
            let sdk = PaymentRequestSdkMock(records: [record])
            let store = PaymentRequestPresentationMemoryStore()
            let manager = paymentRequestManager(sdk: sdk, acceptanceStore: store)
            await manager.refresh()
            let request = try XCTUnwrap(manager.pendingRequests.first)
            await sdk.setAcceptanceResponseError(error)

            do {
                try await manager.prepareForPayment(request)
                XCTFail("The interrupted call must not authorize execution")
            } catch {}
            XCTAssertFalse(manager.isApprovedForPayment(request))
            var accepted = record
            accepted.state = .accepted
            await sdk.setRecords([accepted])
            let restarted = paymentRequestManager(sdk: sdk, acceptanceStore: store)
            await restarted.refresh()
            let retry = try XCTUnwrap(restarted.pendingRequests.first)
            try await restarted.prepareForPayment(retry)
            try await restarted.ensurePaymentAllowed(retry)
        }
    }

    func testFailedAcceptancePreservesAnotherRequestsIntent() async throws {
        let identity = "pubky\(String(repeating: "z", count: 52))"
        let firstRecord = try paymentRequestRecord(id: "first")
        var secondRecord = try paymentRequestRecord(id: "second")
        let sdk = PaymentRequestSdkMock(records: [firstRecord, secondRecord])
        let store = PaymentRequestPresentationMemoryStore()
        let manager = paymentRequestManager(sdk: sdk, acceptanceStore: store)
        await manager.refresh()
        let first = try XCTUnwrap(manager.pendingRequests.first { $0.paymentRequestId == "first" })
        let second = try XCTUnwrap(manager.pendingRequests.first { $0.paymentRequestId == "second" })
        await sdk.pauseNextAccept()

        let acceptance = Task { try await manager.prepareForPayment(first) }
        try await waitUntil { await sdk.acceptIsPaused() }
        try await manager.prepareForPayment(second)
        await sdk.failNextAcceptAfterRemoval()
        await sdk.resumeAccept()
        do {
            try await acceptance.value
            XCTFail("Expected the first acceptance to fail")
        } catch {
            XCTAssertEqual(error as? PaymentRequestSdkMockError, .process)
        }

        XCTAssertEqual(try store.load(identity: identity), [second.id])
        secondRecord.state = .accepted
        await sdk.setRecords([secondRecord])
        let restarted = paymentRequestManager(sdk: sdk, acceptanceStore: store)
        await restarted.refresh()
        XCTAssertEqual(restarted.pendingRequests.map(\.id), [second.id])
    }

    func testFailedAcceptanceDoesNotRemoveIntentFromNewManagerGeneration() async throws {
        let identity = "pubky\(String(repeating: "z", count: 52))"
        let record = try paymentRequestRecord()
        let sdk = PaymentRequestSdkMock(records: [record])
        let store = PaymentRequestPresentationMemoryStore()
        let manager = paymentRequestManager(sdk: sdk, acceptanceStore: store)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        await sdk.pauseNextAccept()

        let acceptance = Task { try await manager.prepareForPayment(request) }
        try await waitUntil { await sdk.acceptIsPaused() }
        manager.clear()
        manager.activate(identity: identity)
        await manager.refresh()
        let current = try XCTUnwrap(manager.pendingRequests.first)
        try await manager.prepareForPayment(current)
        await sdk.resumeAccept()
        do {
            try await acceptance.value
            XCTFail("Expected the superseded acceptance to fail")
        } catch {
            XCTAssertEqual(error as? PaymentRequestSdkMockError, .requestMissing)
        }

        XCTAssertEqual(try store.load(identity: identity), [current.id])
        XCTAssertTrue(manager.isApprovedForPayment(current))
    }

    func testClearingDuringRetryDoesNotReopenRequest() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        try await manager.prepareForPayment(request)
        try await sdk.setRecords([paymentRequestRecord(state: .accepted)])
        await sdk.pauseNextPaymentRequestList()

        let retry = Task { await manager.paymentRequestForRetry(request.id) }
        try await waitUntil { await sdk.paymentRequestListIsPaused() }
        manager.clear()
        await sdk.resumePaymentRequestList()
        let retriedRequest = await retry.value

        XCTAssertNil(retriedRequest)
        XCTAssertTrue(manager.pendingRequests.isEmpty)
    }

    func testClearingDuringSendFlowFinishDoesNotRequeueRequest() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        try await manager.prepareForPayment(request)
        try await sdk.setRecords([paymentRequestRecord(state: .accepted)])
        await sdk.pauseNextPaymentRequestList()

        let finish = Task { await manager.finishPayment(request) }
        try await waitUntil { await sdk.paymentRequestListIsPaused() }
        manager.clear()
        await sdk.resumePaymentRequestList()
        await finish.value

        XCTAssertTrue(manager.pendingRequests.isEmpty)
    }

    func testRefreshKeepsRequestVisibleWhileAcceptanceIsFinishing() async throws {
        let sdk = try PaymentRequestSdkMock(records: [paymentRequestRecord()])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh()
        let request = try XCTUnwrap(manager.pendingRequests.first)
        await sdk.pauseNextAccept()

        let acceptance = Task { try await manager.prepareForPayment(request) }
        try await waitUntil { await sdk.acceptIsPaused() }
        await manager.refresh()

        XCTAssertEqual(manager.pendingRequests, [request])
        XCTAssertFalse(manager.isApprovedForPayment(request))

        await sdk.resumeAccept()
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
        let thirdRecord = try paymentRequestRecord(id: sharedId, counterparty: "pubkyother")
        let fourthRecord = try paymentRequestRecord(id: "650e8400-e29b-41d4-a716-446655440000")
        let remainingIds = [thirdRecord, fourthRecord].map {
            PaykitPaymentRequest.ID(
                paymentRequestId: $0.paymentRequestId,
                counterparty: $0.counterparty
            )
        }
        let sdk = PaymentRequestSdkMock(records: [firstRecord, thirdRecord, fourthRecord])
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refresh(messagePriority: .background)
        let request = try XCTUnwrap(manager.pendingRequests.first(where: {
            $0.paymentRequestId == firstRecord.paymentRequestId &&
                $0.counterparty == firstRecord.counterparty
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
                paymentRequestId: request.paymentRequestId
            )]
        )
        let priorities = await sdk.operationPriorities
        XCTAssertEqual(priorities["pending"], [.background])
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



    func testAcceptanceDefersScopedDeliveryWithoutDrainingMessagesAndDropsWorkAfterIdentityChanges() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let recurrence = PaymentRequestRecurrence(
            every: 1, unit: "month", startsAt: "2027-01-01T08:00:00Z", anchor: "2027-01-01T08:00:00Z", endsAt: nil
        )
        for (recurring, changesIdentity) in [(false, false), (false, true), (true, false), (true, true)] {
            let record = try paymentRequestRecord(recurrence: recurring ? recurrence : nil)
            let sdk = PaymentRequestSdkMock(records: [record])
            let activity = PaykitPaymentActivity()
            let payment = activity.begin()
            defer { activity.end(payment) }
            var scheduledPeers: [String] = []
            let scheduled = expectation(description: "Acceptance delivery scheduled")
            scheduled.isInverted = changesIdentity
            let manager = paymentRequestManager(sdk: sdk, scheduleAcceptedRequestDelivery: {
                scheduledPeers.append($0)
                scheduled.fulfill()
            }, paymentActivity: activity, clock: PaymentRequestTestClock(now))
            await manager.refresh(mode: .stored)
            if recurring {
                let dueRequest = try await manager.accept(XCTUnwrap(manager.subscriptions.first))
                XCTAssertNotNil(dueRequest)
                XCTAssertEqual(manager.subscriptions.first?.lifecycleState, .activeRecurring)
            } else {
                let request = try XCTUnwrap(manager.pendingRequests.first)
                try await manager.prepareForPayment(request)
                XCTAssertTrue(manager.pendingRequests.isEmpty)
                XCTAssertTrue(manager.isApprovedForPayment(request))
            }
            let snapshot = await sdk.snapshot()
            XCTAssertEqual(snapshot.acceptedRequests.map(\.paymentRequestId), [record.paymentRequestId])
            XCTAssertEqual(snapshot.processCallCount, 0)
            XCTAssertTrue(snapshot.processedCounterparties.isEmpty)
            XCTAssertTrue(scheduledPeers.isEmpty)

            if changesIdentity { manager.clear() }
            activity.end(payment)
            await fulfillment(of: [scheduled], timeout: changesIdentity ? 0.1 : 2)
            XCTAssertEqual(scheduledPeers, changesIdentity ? [] : [record.counterparty])
        }
    }

    func testOnchainResolutionRemainsAvailableForTheMatchingSendUntilConsumed() throws {
        let app = AppViewModel()
        let identity = "pubky" + String(repeating: "y", count: 52)
        let otherIdentity = "pubky" + String(repeating: "b", count: 52)
        let request = try XCTUnwrap(PaykitPaymentRequest(record: paymentRequestRecord(), now: Date()))
        app.contactPaymentContext = ContactPaymentContext(publicKey: request.counterparty, incomingPaymentRequest: request)
        let resolution = PaykitOnchainPaymentResolution(identity: identity, requestId: request.id, transactionId: "resolved-tx")
        let unrelated = PaykitOnchainPaymentResolution(
            identity: identity,
            requestId: PaykitPaymentRequest.ID(paymentRequestId: "other", counterparty: request.counterparty),
            transactionId: "other-tx"
        )

        app.retainPaykitOnchainPaymentResolution(resolution, identity: otherIdentity)
        XCTAssertNil(app.paykitOnchainPaymentResolution)
        app.retainPaykitOnchainPaymentResolution(resolution, identity: identity)
        app.retainPaykitOnchainPaymentResolution(unrelated, identity: identity)
        app.consumePaykitOnchainPaymentResolution(unrelated)
        app.resetSendState(preservingContactPaymentContext: true)
        XCTAssertEqual(app.paykitOnchainPaymentResolution, resolution)
        app.consumePaykitOnchainPaymentResolution(resolution)
        XCTAssertNil(app.paykitOnchainPaymentResolution)

        app.retainPaykitOnchainPaymentResolution(resolution, identity: identity)
        app.resetSendState()
        XCTAssertNil(app.paykitOnchainPaymentResolution)
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
        let refreshed = await refreshTask.value

        XCTAssertFalse(refreshed)
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
            scheduleAcceptedRequestDelivery: { _ in },
            service: PaykitPaymentRequestService(sdk: sdk, logWarning: { _ in }),
            presentationStore: store,
            acceptanceStore: PaymentRequestPresentationMemoryStore(),
            subscriptionStateStore: subscriptionStore,
            logWarning: { _ in }
        )
        firstManager.activate(identity: identity)
        await firstManager.refresh()
        let request = try XCTUnwrap(firstManager.pendingRequests.first)
        XCTAssertTrue(firstManager.markPresentedIfPending(request))

        let restoredManager = PaykitPaymentRequestManager(
            scheduleAcceptedRequestDelivery: { _ in },
            service: PaykitPaymentRequestService(sdk: sdk, logWarning: { _ in }),
            presentationStore: store,
            acceptanceStore: PaymentRequestPresentationMemoryStore(),
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
            scheduleAcceptedRequestDelivery: { _ in },
            service: PaykitPaymentRequestService(sdk: sdk, logWarning: { _ in }),
            presentationStore: presentationStore,
            acceptanceStore: PaymentRequestPresentationMemoryStore(),
            subscriptionStateStore: subscriptionStore,
            logWarning: { _ in }
        )
        firstManager.activate(identity: identity)
        await firstManager.refresh()
        let subscription = try XCTUnwrap(firstManager.subscriptionProposalForPresentation())
        firstManager.markSubscriptionProposalPresented(subscription)

        let restoredManager = PaykitPaymentRequestManager(
            scheduleAcceptedRequestDelivery: { _ in },
            service: PaykitPaymentRequestService(sdk: sdk, logWarning: { _ in }),
            presentationStore: presentationStore,
            acceptanceStore: PaymentRequestPresentationMemoryStore(),
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

    func testEligibleTargetsRequireSavedLinkedPaymentRequestCapableContact() async {
        let savedKey = "pubky\(String(repeating: "y", count: 52))"
        let unsavedKey = "pubky\(String(repeating: "b", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [
                linkedPeer(counterparty: savedKey, state: .linking),
                linkedPeer(counterparty: savedKey, state: .linked),
                linkedPeer(counterparty: unsavedKey, state: .linked),
            ],
            requestCapabilitiesByPublicKey: [
                savedKey: true,
                unsavedKey: true,
            ]
        )
        let manager = paymentRequestManager(sdk: sdk)

        await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])

        XCTAssertEqual(
            manager.eligibleTargets,
            [PaykitPaymentRequestTarget(publicKey: savedKey)]
        )
        let priorities = await sdk.operationPriorities
        XCTAssertEqual(priorities["identity"], [.background])
        XCTAssertEqual(priorities["peers"], [.background])
    }

    func testCapabilityDiscoveryBoundsConcurrentReadsWithoutWaitingForSlowPeer() async throws {
        let keys = "ybndrfg8ejkmcpqxot".map { "pubky" + String(repeating: String($0), count: 52) }
        let sdk = PaymentRequestSdkMock(records: [])
        var supported = Dictionary(uniqueKeysWithValues: keys.map { ($0, true) })
        supported[keys[5]] = false
        await sdk.configureRecipients(
            peers: keys.map { linkedPeer(counterparty: $0, state: .linked) },
            requestCapabilitiesByPublicKey: supported
        )
        await sdk.setCapabilityLookupFailing(true, for: keys[2])
        let (slowGate, releaseSlow) = AsyncStream<Void>.makeStream()
        let (batchGate, releaseBatch) = AsyncStream<Void>.makeStream()
        defer { releaseSlow.finish(); releaseBatch.finish() }
        await sdk.setCapabilityLookupGate { key in
            let gate = key == keys[0] ? slowGate : batchGate
            for await _ in gate {}
        }
        let service = PaykitPaymentRequestService(sdk: sdk, isPrivatePaymentPublishingEnabled: { true }, logWarning: { _ in })
        let discovery = Task {
            try await service.discoverEligibleTargets(
                savedPublicKeys: keys + [keys[0]],
                expectedIdentity: "pubky\(String(repeating: "z", count: 52))",
                previousTargets: [PaykitPaymentRequestTarget(publicKey: keys[2])]
            )
        }
        try await waitUntil { await sdk.activeCapabilityLookups == 8 }
        let initialLookups = await sdk.capabilityLookupPublicKeys
        XCTAssertEqual(Set(initialLookups), Set(keys.prefix(8)))
        releaseBatch.finish()
        try await waitUntil {
            let lookups = await sdk.capabilityLookups()
            let active = await sdk.activeCapabilityLookups
            return lookups == keys.count && active == 1
        }
        let highWaterMark = await sdk.maxConcurrentCapabilityLookups
        XCTAssertEqual(highWaterMark, 8)

        releaseSlow.finish()
        let result = try await discovery.value
        XCTAssertEqual(result.targets.map(\.publicKey), keys.filter { $0 != keys[5] })
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.capabilityCheckedPublicKeys, Set(keys).subtracting([keys[2]]))
    }

    func testCancelledCapabilityDiscoveryDoesNotStartAnotherBatch() async throws {
        let keys = "ybndrfg8ejkmcpqxot".map { "pubky" + String(repeating: String($0), count: 52) }
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: keys.map { linkedPeer(counterparty: $0, state: .linked) },
            requestCapabilitiesByPublicKey: Dictionary(uniqueKeysWithValues: keys.map { ($0, true) })
        )
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        await sdk.setCapabilityLookupGate { _ in for await _ in gate {} }
        let service = PaykitPaymentRequestService(sdk: sdk, isPrivatePaymentPublishingEnabled: { true })
        let discovery = Task {
            try await service.discoverEligibleTargets(
                savedPublicKeys: keys, expectedIdentity: "pubky\(String(repeating: "z", count: 52))"
            )
        }
        try await waitUntil { await sdk.activeCapabilityLookups == 8 }
        discovery.cancel()
        release.finish()
        do {
            _ = try await discovery.value
            XCTFail("Cancelled discovery must not return partial eligibility")
        } catch is CancellationError {}
        let lookups = await sdk.capabilityLookups()
        XCTAssertEqual(lookups, 8)
    }

    func testEligibleTargetsRequireLivePaykitSession() async {
        let savedKey = "pubky\(String(repeating: "y", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: savedKey, state: .linked)],
            requestCapabilitiesByPublicKey: [savedKey: true]
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
            peers: [linkedPeer(counterparty: savedKey, state: .linked)],
            requestCapabilitiesByPublicKey: [savedKey: true]
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
            peers: [linkedPeer(counterparty: savedKey, state: .linked)],
            requestCapabilitiesByPublicKey: [savedKey: true]
        )
        let manager = paymentRequestManager(sdk: sdk, isPrivatePaymentPublishingEnabled: false)

        await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])

        XCTAssertTrue(manager.eligibleTargets.isEmpty)
    }

    func testEligibleTargetsKeepPreviousTargetWhenCapabilityLookupFails() async {
        let savedKey = "pubky\(String(repeating: "y", count: 52))"
        let target = PaykitPaymentRequestTarget(publicKey: savedKey)
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: savedKey, state: .linked)],
            requestCapabilitiesByPublicKey: [savedKey: true]
        )
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])

        await sdk.setCapabilityLookupFailing(true, for: savedKey)
        await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])

        XCTAssertEqual(manager.eligibleTargets, [target])
    }

    func testEligibleTargetsSurviveLinkedPeerLookupFailure() async {
        let savedKey = "pubky\(String(repeating: "y", count: 52))"
        let target = PaykitPaymentRequestTarget(publicKey: savedKey)
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: savedKey, state: .linked)],
            requestCapabilitiesByPublicKey: [savedKey: true]
        )
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])

        await sdk.setLinkedPeersError(.linkedPeers)
        await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])

        XCTAssertEqual(manager.eligibleTargets, [target])
    }

    func testSingleEligibilityRefreshAddsNewlyEligibleContact() async {
        let firstKey = "pubky\(String(repeating: "a", count: 52))"
        let secondKey = "pubky\(String(repeating: "b", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: firstKey, state: .linked)],
            requestCapabilitiesByPublicKey: [firstKey: true]
        )
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refreshEligibleTargets(savedPublicKeys: [firstKey, secondKey])
        await sdk.configureRecipients(
            peers: [
                linkedPeer(counterparty: firstKey, state: .linked),
                linkedPeer(counterparty: secondKey, state: .linked),
            ],
            requestCapabilitiesByPublicKey: [
                firstKey: true,
                secondKey: true,
            ]
        )

        let target = await manager.refreshEligibleTarget(publicKey: secondKey)

        let expected = PaykitPaymentRequestTarget(publicKey: secondKey)
        XCTAssertEqual(target, expected)
        XCTAssertEqual(
            manager.eligibleTargets,
            [PaykitPaymentRequestTarget(publicKey: firstKey), expected]
        )
    }

    func testSelectedRecipientCanRefreshBeforeFullContactDiscovery() async {
        let selected = "pubky\(String(repeating: "a", count: 52))"
        let unrelated = "pubky\(String(repeating: "b", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: selected, state: .linked), linkedPeer(counterparty: unrelated, state: .linked)],
            requestCapabilitiesByPublicKey: [selected: true, unrelated: true]
        )
        let manager = paymentRequestManager(sdk: sdk)
        manager.updateSavedPublicKeys([selected, unrelated])

        let target = await manager.refreshEligibleTarget(publicKey: selected)

        XCTAssertEqual(target, PaykitPaymentRequestTarget(publicKey: selected))
        let lookups = await sdk.capabilityLookupPublicKeys
        XCTAssertEqual(lookups, [selected])
    }

    func testSavedContactUpdateImmediatelyRemovesTargetWithoutNetworkDiscovery() async {
        let key = "pubky\(String(repeating: "a", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: key, state: .linked)],
            requestCapabilitiesByPublicKey: [key: true]
        )
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refreshEligibleTargets(savedPublicKeys: [key])

        manager.updateSavedPublicKeys([])
        let target = await manager.refreshEligibleTarget(publicKey: key)

        XCTAssertNil(target)
        XCTAssertTrue(manager.eligibleTargets.isEmpty)
        let lookups = await sdk.capabilityLookupPublicKeys
        XCTAssertEqual(lookups, [key])
    }

    func testOnlyTheRefreshOfEverySavedContactReadsCapabilitiesInBulk() async throws {
        let savedKey = "pubky\(String(repeating: "y", count: 52))"
        let expiresAt = Date(timeIntervalSince1970: 1_900_000_000)
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: savedKey, state: .linked)],
            requestCapabilitiesByPublicKey: [savedKey: true]
        )
        try await sdk.setProposalResult(paymentRequestRecord(
            id: "outgoing",
            counterparty: savedKey,
            role: .payee,
            expiresAt: timestamp(expiresAt)
        ))
        let manager = paymentRequestManager(sdk: sdk)

        await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])
        let target = await manager.refreshEligibleTarget(publicKey: savedKey)
        _ = try await manager.propose(
            PaykitPaymentRequestDraft(amountSats: 1, note: "Coffee", expiresAt: expiresAt),
            to: XCTUnwrap(target)
        )

        let priorities = await sdk.capabilityReadPriorities()
        XCTAssertEqual(
            priorities,
            [.bulk, .interactive, .interactive],
            "Contact detail's Pay check and a proposal must not queue behind the Contacts list's bulk reads"
        )
    }

    func testSingleEligibilityRefreshRemovesContactThatIsNoLongerLinked() async {
        let savedKey = "pubky\(String(repeating: "y", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: savedKey, state: .linked)],
            requestCapabilitiesByPublicKey: [savedKey: true]
        )
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])
        await sdk.configureRecipients(peers: [], requestCapabilitiesByPublicKey: [savedKey: true])

        let target = await manager.refreshEligibleTarget(publicKey: savedKey)

        XCTAssertNil(target)
        XCTAssertTrue(manager.eligibleTargets.isEmpty)
    }

    func testSingleEligibilityRefreshIgnoresUnsavedContact() async {
        let unsavedKey = "pubky\(String(repeating: "b", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: unsavedKey, state: .linked)],
            requestCapabilitiesByPublicKey: [unsavedKey: true]
        )
        let manager = paymentRequestManager(sdk: sdk)

        let target = await manager.refreshEligibleTarget(publicKey: unsavedKey)

        XCTAssertNil(target)
        XCTAssertTrue(manager.eligibleTargets.isEmpty)
    }

    func testWaitingForEligibleTargetCancelsLookupAtTimeout() async throws {
        let savedKey = "pubky\(String(repeating: "y", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: savedKey, state: .linked)],
            requestCapabilitiesByPublicKey: [savedKey: true]
        )
        let manager = paymentRequestManager(sdk: sdk)
        await sdk.setLinkedPeersError(.linkedPeers)
        await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])
        await sdk.setLinkedPeersError(nil)
        await sdk.pauseNextLinkedPeers()

        let target = await manager.eligibleTarget(publicKey: savedKey, waitingAtMost: .milliseconds(50))

        XCTAssertNil(target)
        try await waitUntil { await sdk.linkedPeersIsPaused() }
        let abandonedRefresh = manager.startEligibleTargetRefresh(publicKey: savedKey)
        await sdk.resumeLinkedPeers()
        let abandonedTarget = await abandonedRefresh.value
        XCTAssertNil(abandonedTarget)
        let lookups = await sdk.capabilityLookups()
        XCTAssertEqual(lookups, 0)
        XCTAssertTrue(manager.eligibleTargets.isEmpty)

        let refreshed = await manager.startEligibleTargetRefresh(publicKey: savedKey).value
        XCTAssertEqual(refreshed, PaykitPaymentRequestTarget(publicKey: savedKey))
    }

    func testSingleEligibilityRefreshRemovesContactThatStoppedAcceptingRequests() async {
        let savedKey = "pubky\(String(repeating: "y", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: savedKey, state: .linked)],
            requestCapabilitiesByPublicKey: [savedKey: true]
        )
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: savedKey, state: .linked)],
            requestCapabilitiesByPublicKey: [savedKey: false]
        )

        let target = await manager.refreshEligibleTarget(publicKey: savedKey)

        XCTAssertNil(target)
        XCTAssertTrue(manager.eligibleTargets.isEmpty)
    }

    func testFailedEligibilityRefreshDropsDeletedContacts() async {
        let keptKey = "pubky\(String(repeating: "a", count: 52))"
        let deletedKey = "pubky\(String(repeating: "b", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [
                linkedPeer(counterparty: keptKey, state: .linked),
                linkedPeer(counterparty: deletedKey, state: .linked),
            ],
            requestCapabilitiesByPublicKey: [
                keptKey: true,
                deletedKey: true,
            ]
        )
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refreshEligibleTargets(savedPublicKeys: [keptKey, deletedKey])

        await sdk.setLinkedPeersError(.linkedPeers)
        await manager.refreshEligibleTargets(savedPublicKeys: [keptKey])

        XCTAssertEqual(
            manager.eligibleTargets,
            [PaykitPaymentRequestTarget(publicKey: keptKey)]
        )
    }

    func testFailedFullRefreshCannotRemoveNewlySavedEligibleTarget() async throws {
        let firstKey = "pubky\(String(repeating: "a", count: 52))"
        let addedKey = "pubky\(String(repeating: "b", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: addedKey, state: .linked)],
            requestCapabilitiesByPublicKey: [addedKey: true]
        )
        await sdk.setLinkedPeersError(.linkedPeers)
        await sdk.pauseNextLinkedPeers()
        let manager = paymentRequestManager(sdk: sdk)

        let fullRefresh = Task {
            await manager.refreshEligibleTargets(savedPublicKeys: [firstKey])
        }
        try await waitUntil { await sdk.linkedPeersIsPaused() }
        manager.updateSavedPublicKeys([firstKey, addedKey])
        await sdk.setLinkedPeersError(nil)
        let target = await manager.refreshEligibleTarget(publicKey: addedKey)
        await sdk.resumeLinkedPeers()
        await fullRefresh.value

        XCTAssertEqual(target, PaykitPaymentRequestTarget(publicKey: addedKey))
        XCTAssertEqual(manager.eligibleTargets, [PaykitPaymentRequestTarget(publicKey: addedKey)])
        let immediateTarget = await manager.eligibleTarget(publicKey: addedKey, waitingAtMost: .seconds(2))
        XCTAssertEqual(immediateTarget, target)
        let lookups = await sdk.capabilityLookupPublicKeys
        XCTAssertEqual(lookups, [addedKey])
    }

    func testReorderedSavedKeysAllowPendingEligibilityRefreshToComplete() async throws {
        let savedKey = "pubky\(String(repeating: "y", count: 52))"
        let otherKey = "pubky\(String(repeating: "a", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: savedKey, state: .linked)],
            requestCapabilitiesByPublicKey: [savedKey: true]
        )
        await sdk.pauseNextLinkedPeers()
        let manager = paymentRequestManager(sdk: sdk)

        let fullRefresh = Task {
            await manager.refreshEligibleTargets(savedPublicKeys: [savedKey, otherKey])
        }
        try await waitUntil { await sdk.linkedPeersIsPaused() }
        manager.updateSavedPublicKeys([otherKey, savedKey])
        await sdk.resumeLinkedPeers()
        await fullRefresh.value

        XCTAssertEqual(manager.eligibleTargets, [PaykitPaymentRequestTarget(publicKey: savedKey)])
    }

    func testSingleEligibilityRefreshCannotOverwriteNewerFullRefresh() async throws {
        let savedKey = "pubky\(String(repeating: "y", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: savedKey, state: .linked)],
            requestCapabilitiesByPublicKey: [savedKey: true]
        )
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])
        await sdk.pauseNextLinkedPeers()

        let singleRefresh = Task {
            await manager.refreshEligibleTarget(publicKey: savedKey)
        }
        try await waitUntil { await sdk.linkedPeersIsPaused() }
        await sdk.configureRecipients(peers: [], requestCapabilitiesByPublicKey: [savedKey: true])
        await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])
        await sdk.resumeLinkedPeers()
        let target = await singleRefresh.value

        XCTAssertNil(target)
        XCTAssertTrue(manager.eligibleTargets.isEmpty)
    }

    func testOlderFullRefreshCannotOverwriteNewerSingleRefresh() async throws {
        let savedKey = "pubky\(String(repeating: "y", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: savedKey, state: .linked)],
            requestCapabilitiesByPublicKey: [savedKey: true]
        )
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])
        await sdk.pauseNextLinkedPeers()

        let fullRefresh = Task {
            await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])
        }
        try await waitUntil { await sdk.linkedPeersIsPaused() }
        await sdk.configureRecipients(peers: [], requestCapabilitiesByPublicKey: [savedKey: true])
        let target = await manager.refreshEligibleTarget(publicKey: savedKey)
        await sdk.resumeLinkedPeers()
        await fullRefresh.value

        XCTAssertNil(target)
        XCTAssertTrue(manager.eligibleTargets.isEmpty)
    }

    func testFullRefreshKeepsOtherContactsWhenSingleRefreshFinishesFirst() async throws {
        let refreshedKey = "pubky\(String(repeating: "a", count: 52))"
        let otherKey = "pubky\(String(repeating: "b", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: refreshedKey, state: .linked)],
            requestCapabilitiesByPublicKey: [refreshedKey: true, otherKey: true]
        )
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refreshEligibleTargets(savedPublicKeys: [refreshedKey, otherKey])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: otherKey, state: .linked)],
            requestCapabilitiesByPublicKey: [refreshedKey: true, otherKey: true]
        )
        await sdk.pauseNextLinkedPeers()

        let fullRefresh = Task {
            await manager.refreshEligibleTargets(savedPublicKeys: [refreshedKey, otherKey])
        }
        try await waitUntil { await sdk.linkedPeersIsPaused() }
        await sdk.configureRecipients(
            peers: [
                linkedPeer(counterparty: refreshedKey, state: .linked),
                linkedPeer(counterparty: otherKey, state: .linked),
            ],
            requestCapabilitiesByPublicKey: [refreshedKey: true, otherKey: true]
        )
        _ = await manager.refreshEligibleTarget(publicKey: refreshedKey)
        await sdk.resumeLinkedPeers()
        await fullRefresh.value

        XCTAssertEqual(
            Set(manager.eligibleTargets),
            [
                PaykitPaymentRequestTarget(publicKey: refreshedKey),
                PaykitPaymentRequestTarget(publicKey: otherKey),
            ]
        )
    }

    func testFailedSingleRefreshDoesNotOverrideOverlappingFullRefresh() async throws {
        let savedKey = "pubky\(String(repeating: "y", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: savedKey, state: .linked)],
            requestCapabilitiesByPublicKey: [savedKey: true]
        )
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])
        await sdk.pauseNextLinkedPeers()

        let fullRefresh = Task {
            await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])
        }
        try await waitUntil { await sdk.linkedPeersIsPaused() }
        await sdk.setCapabilityLookupFailing(true, for: savedKey)
        let target = await manager.refreshEligibleTarget(publicKey: savedKey)
        await sdk.setCapabilityLookupFailing(false, for: savedKey)
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: savedKey, state: .linked)],
            requestCapabilitiesByPublicKey: [savedKey: false]
        )
        await sdk.resumeLinkedPeers()
        await fullRefresh.value

        XCTAssertEqual(target, PaykitPaymentRequestTarget(publicKey: savedKey))
        XCTAssertTrue(manager.eligibleTargets.isEmpty)
    }

    func testWaitingForEligibleTargetSkipsRecentlyCheckedContact() async {
        let savedKey = "pubky\(String(repeating: "y", count: 52))"
        let clock = PaymentRequestTestClock(Date())
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: savedKey, state: .linked)],
            requestCapabilitiesByPublicKey: [savedKey: false]
        )
        let manager = paymentRequestManager(sdk: sdk, clock: clock)
        await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])
        let callsAfterRefresh = await sdk.linkedPeersCalls()

        let target = await manager.eligibleTarget(publicKey: savedKey, waitingAtMost: .seconds(2))

        XCTAssertNil(target)
        let callsAfterWait = await sdk.linkedPeersCalls()
        XCTAssertEqual(callsAfterWait, callsAfterRefresh)
    }

    func testWaitingForEligibleTargetRechecksContactThatWasStillLinking() async {
        let savedKey = "pubky\(String(repeating: "y", count: 52))"
        for fullRefresh in [false, true] {
            let sdk = PaymentRequestSdkMock(records: [])
            await sdk.configureRecipients(
                peers: [linkedPeer(counterparty: savedKey, state: .linking)],
                requestCapabilitiesByPublicKey: [savedKey: true]
            )
            let manager = paymentRequestManager(sdk: sdk)
            manager.updateSavedPublicKeys([savedKey])
            if fullRefresh {
                await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])
            } else {
                _ = await manager.refreshEligibleTarget(publicKey: savedKey)
            }
            await sdk.configureRecipients(
                peers: [linkedPeer(counterparty: savedKey, state: .linked)],
                requestCapabilitiesByPublicKey: [savedKey: true]
            )

            let target = await manager.eligibleTarget(publicKey: savedKey, waitingAtMost: .seconds(2))

            XCTAssertEqual(target, PaykitPaymentRequestTarget(publicKey: savedKey))
            let lookups = await sdk.capabilityLookupPublicKeys
            XCTAssertEqual(lookups, [savedKey])
        }
    }

    func testWaitingForEligibleTargetRechecksAfterRecentWindow() async {
        let savedKey = "pubky\(String(repeating: "y", count: 52))"
        let clock = PaymentRequestTestClock(Date())
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: savedKey, state: .linked)],
            requestCapabilitiesByPublicKey: [savedKey: false]
        )
        let manager = paymentRequestManager(sdk: sdk, clock: clock)
        await manager.refreshEligibleTargets(savedPublicKeys: [savedKey])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: savedKey, state: .linked)],
            requestCapabilitiesByPublicKey: [savedKey: true]
        )
        clock.advance(by: 31)

        let target = await manager.eligibleTarget(publicKey: savedKey, waitingAtMost: .seconds(2))

        XCTAssertEqual(target, PaykitPaymentRequestTarget(publicKey: savedKey))
    }

    func testOlderEligibilityRefreshCannotOverwriteNewerContacts() async throws {
        let firstKey = "pubky\(String(repeating: "a", count: 52))"
        let secondKey = "pubky\(String(repeating: "b", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: firstKey, state: .linked)],
            requestCapabilitiesByPublicKey: [firstKey: true]
        )
        await sdk.pauseNextLinkedPeers()
        let manager = paymentRequestManager(sdk: sdk)

        let olderRefresh = Task {
            await manager.refreshEligibleTargets(savedPublicKeys: [firstKey])
        }
        try await waitUntil { await sdk.linkedPeersIsPaused() }
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: secondKey, state: .linked)],
            requestCapabilitiesByPublicKey: [secondKey: true]
        )
        await manager.refreshEligibleTargets(savedPublicKeys: [secondKey])
        await sdk.resumeLinkedPeers()
        await olderRefresh.value

        XCTAssertEqual(
            manager.eligibleTargets,
            [PaykitPaymentRequestTarget(publicKey: secondKey)]
        )
    }

    func testProposeBuildsOneTimeBitcoinTermsAndDrainsOutbox() async throws {
        let publicKey = "pubky\(String(repeating: "y", count: 52))"
        let sdk = PaymentRequestSdkMock(records: [])
        let expiresAt = Date(timeIntervalSince1970: 1_900_000_000)
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: publicKey, state: .linked)],
            requestCapabilitiesByPublicKey: [publicKey: true]
        )
        try await sdk.setProposalResult(paymentRequestRecord(
            id: "outgoing",
            counterparty: publicKey,
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
        XCTAssertEqual(snapshot.processCallCount, 0)
        XCTAssertEqual(snapshot.processedCounterparties, [publicKey])
        let priorities = await sdk.operationPriorities
        XCTAssertEqual(priorities["identity"], [.background, .interactive])
        XCTAssertEqual(priorities["peers"], [.background, .interactive])
        XCTAssertEqual(priorities["delivery"], [.interactive])
    }

    func testProposalsOnlyInspectAndDrainSelectedSavedTarget() async throws {
        let publicKey = "pubky\(String(repeating: "y", count: 52))"
        let unrelatedKey = "pubky\(String(repeating: "a", count: 52))"
        let expectedIdentity = "pubky\(String(repeating: "z", count: 52))"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiresAt = now.addingTimeInterval(60)
        let target = PaykitPaymentRequestTarget(publicKey: publicKey)
        let savedPublicKeys = [unrelatedKey, String(publicKey.dropFirst(5)), publicKey]

        for isSubscription in [false, true] {
            let sdk = PaymentRequestSdkMock(records: [])
            await sdk.configureRecipients(
                peers: [
                    linkedPeer(counterparty: unrelatedKey, state: .linked),
                    linkedPeer(counterparty: publicKey, state: .linked),
                ],
                requestCapabilitiesByPublicKey: [publicKey: true, unrelatedKey: true]
            )
            await sdk.setCapabilityLookupFailing(true, for: unrelatedKey)
            try await sdk.setProposalResult(paymentRequestRecord(
                counterparty: publicKey, role: .payee, proposalOutboundMessageId: 7
            ))
            await sdk.setProcessReports([OutboundPrivateCounterpartySendReport(
                counterparty: publicKey,
                report: OutboundPrivateSendReport(
                    attempted: [7], sent: [7], failed: [], reservationCleanupFailures: [], recoveryMarkerFailures: []
                ),
                error: nil
            )])
            await sdk.pauseNextProcess(for: unrelatedKey)
            let service = PaykitPaymentRequestService(
                sdk: sdk, now: { now }, isPrivatePaymentPublishingEnabled: { true }, logWarning: { _ in }
            )

            let completed = expectation(description: "Selected proposal completes without unrelated delivery")
            let proposal = Task {
                let status: PaykitPaymentRequest.DeliveryStatus? = if isSubscription {
                    try await service.proposeSubscription(
                        PaykitSubscriptionDraft(
                            amountSats: 1000, name: "Support", description: "", frequency: .month,
                            expiresAt: expiresAt, iconData: nil
                        ),
                        to: target, savedPublicKeys: savedPublicKeys, expectedIdentity: expectedIdentity,
                        validateBeforeProposing: {}
                    ).deliveryStatus
                } else {
                    try await service.propose(
                        PaykitPaymentRequestDraft(amountSats: 1000, note: "Support", expiresAt: expiresAt),
                        to: target, savedPublicKeys: savedPublicKeys, expectedIdentity: expectedIdentity
                    ).deliveryStatus
                }
                completed.fulfill()
                return status
            }
            await fulfillment(of: [completed], timeout: 1)
            await sdk.resumeProcess()
            let status = try await proposal.value

            XCTAssertEqual(status, .sent)
            let lookups = await sdk.capabilityLookupPublicKeys
            XCTAssertEqual(lookups, isSubscription ? [publicKey, publicKey] : [publicKey])
            let snapshot = await sdk.snapshot()
            XCTAssertEqual(snapshot.proposedRequests.map(\.counterparty), [publicKey])
            XCTAssertEqual(snapshot.processedCounterparties, [publicKey])
            XCTAssertEqual(snapshot.processCallCount, 0)
            XCTAssertEqual(snapshot.paymentRequestListCallCount, 0)
        }
    }

    func testProposalsUseFreshDeliveryStatusOnlyForTheCommittedProposal() async throws {
        let publicKey = "pubky\(String(repeating: "y", count: 52))"
        let expectedIdentity = "pubky\(String(repeating: "z", count: 52))"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiresAt = now.addingTimeInterval(60)
        let record = try paymentRequestRecord(counterparty: publicKey, role: .payee, proposalOutboundMessageId: 7)
        var sent = record
        sent.proposalOutboundStatus = .sent
        var otherMessage = sent
        otherMessage.proposalOutboundMessageId = 8
        var otherRequest = sent
        otherRequest.paymentRequestId = "another-request"
        var otherPeer = sent
        otherPeer.counterparty = expectedIdentity
        var otherRole = sent
        otherRole.localRole = .payer
        let cases: [(PaymentRequestRecord?, UInt64?, Bool, PaykitPaymentRequest.DeliveryStatus)] = [
            (sent, nil, false, .sent), (record, nil, false, .queued), (nil, nil, false, .queued),
            (otherMessage, nil, false, .queued), (otherRequest, nil, false, .queued),
            (otherPeer, nil, false, .queued), (otherRole, nil, false, .queued),
            (record, 7, false, .queued), (sent, 8, false, .sent), (sent, nil, true, .sent),
        ]

        for isSubscription in [false, true] {
            for (freshRecord, failedMessageId, processFails, expectedStatus) in cases {
                let sdk = PaymentRequestSdkMock(records: [])
                await sdk.configureRecipients(
                    peers: [linkedPeer(counterparty: publicKey, state: .linked)],
                    requestCapabilitiesByPublicKey: [publicKey: true]
                )
                await sdk.setProposalResult(record)
                if let failedMessageId {
                    await sdk.setProcessReports([OutboundPrivateCounterpartySendReport(
                        counterparty: publicKey,
                        report: OutboundPrivateSendReport(
                            attempted: [failedMessageId], sent: [],
                            failed: [OutboundPrivateSendFailure(
                                outboundMessageId: failedMessageId, error: PaymentRequestIntakeError(noPointer: .init())
                            )],
                            reservationCleanupFailures: [], recoveryMarkerFailures: []
                        ),
                        error: nil
                    )])
                }
                if processFails { await sdk.failNextProcess() }
                await sdk.pauseNextProcess()
                let service = PaykitPaymentRequestService(
                    sdk: sdk, now: { now }, isPrivatePaymentPublishingEnabled: { true }, logWarning: { _ in }
                )
                let target = PaykitPaymentRequestTarget(publicKey: publicKey)
                let proposal = Task {
                    if isSubscription {
                        return try await service.proposeSubscription(
                            PaykitSubscriptionDraft(
                                amountSats: 1000, name: "Support", description: "", frequency: .month,
                                expiresAt: expiresAt, iconData: nil
                            ),
                            to: target, savedPublicKeys: [publicKey], expectedIdentity: expectedIdentity,
                            validateBeforeProposing: {}
                        ).deliveryStatus
                    }
                    return try await service.propose(
                        PaykitPaymentRequestDraft(amountSats: 1000, note: "Support", expiresAt: expiresAt),
                        to: target, savedPublicKeys: [publicKey], expectedIdentity: expectedIdentity
                    ).deliveryStatus
                }
                try await waitUntil { await sdk.processIsPaused() }
                await sdk.setRecords(freshRecord.map { [$0] } ?? [])
                await sdk.resumeProcess()

                let status = try await proposal.value
                XCTAssertEqual(status, expectedStatus)
                let snapshot = await sdk.snapshot()
                XCTAssertEqual(snapshot.proposedRequests.count, 1)
                XCTAssertEqual(snapshot.paymentRequestListCallCount, failedMessageId == 7 ? 0 : 1)
            }
        }
    }

    func testProposeRemainsCreatedWhenDeliveryStatusReadFails() async throws {
        let publicKey = "pubky\(String(repeating: "y", count: 52))"
        let expiresAt = Date(timeIntervalSince1970: 1_900_000_000)
        for error in [PaymentRequestSdkMockError.process, CancellationError()] as [Error] {
            let sdk = PaymentRequestSdkMock(records: [])
            await sdk.configureRecipients(
                peers: [linkedPeer(counterparty: publicKey, state: .linked)],
                requestCapabilitiesByPublicKey: [publicKey: true]
            )
            try await sdk.setProposalResult(paymentRequestRecord(
                id: "outgoing", counterparty: publicKey, role: .payee, proposalOutboundMessageId: 7
            ))
            await sdk.setPaymentRequestListError(error)
            let manager = paymentRequestManager(sdk: sdk)
            await manager.refreshEligibleTargets(savedPublicKeys: [publicKey])

            let request = try await manager.propose(
                PaykitPaymentRequestDraft(amountSats: 1, note: "", expiresAt: expiresAt),
                to: XCTUnwrap(manager.eligibleTargets.first)
            )

            XCTAssertEqual(request.deliveryStatus, .queued)
            XCTAssertEqual(manager.outgoingRequests.map(\.paymentRequestId), ["outgoing"])
            let snapshot = await sdk.snapshot()
            XCTAssertEqual(snapshot.proposedRequests.count, 1)
        }
    }

    func testProposalDoesNotUseDeliveryStatusFromAReplacementIdentity() async throws {
        let publicKey = "pubky\(String(repeating: "y", count: 52))"
        let expiresAt = Date(timeIntervalSince1970: 1_900_000_000)
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: publicKey, state: .linked)],
            requestCapabilitiesByPublicKey: [publicKey: true]
        )
        var record = try paymentRequestRecord(
            id: "outgoing", counterparty: publicKey, role: .payee, proposalOutboundMessageId: 7
        )
        await sdk.setProposalResult(record)
        await sdk.pauseNextProcess()
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refreshEligibleTargets(savedPublicKeys: [publicKey])
        let target = try XCTUnwrap(manager.eligibleTargets.first)
        let proposal = Task {
            try await manager.propose(
                PaykitPaymentRequestDraft(amountSats: 1, note: "", expiresAt: expiresAt), to: target
            )
        }
        try await waitUntil { await sdk.processIsPaused() }
        let replacementIdentity = "pubky\(String(repeating: "a", count: 52))"
        manager.activate(identity: replacementIdentity)
        await sdk.setActiveIdentity(replacementIdentity)
        record.proposalOutboundStatus = .sent
        await sdk.setRecords([record])
        await sdk.resumeProcess()

        let request = try await proposal.value
        XCTAssertEqual(request.deliveryStatus, .queued)
        XCTAssertTrue(manager.outgoingRequests.isEmpty)
        let snapshot = await sdk.snapshot()
        XCTAssertEqual(snapshot.proposedRequests.count, 1)
        XCTAssertEqual(snapshot.paymentRequestListCallCount, 0)
    }

    func testProposalsRejectUnsavedSelectedTarget() async throws {
        let publicKey = "pubky\(String(repeating: "y", count: 52))"
        let unrelatedKey = "pubky\(String(repeating: "a", count: 52))"
        let expectedIdentity = "pubky\(String(repeating: "z", count: 52))"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiresAt = now.addingTimeInterval(60)
        let target = PaykitPaymentRequestTarget(publicKey: publicKey)

        for isSubscription in [false, true] {
            let sdk = PaymentRequestSdkMock(records: [])
            await sdk.configureRecipients(
                peers: [
                    linkedPeer(counterparty: publicKey, state: .linked),
                    linkedPeer(counterparty: unrelatedKey, state: .linked),
                ],
                requestCapabilitiesByPublicKey: [publicKey: true, unrelatedKey: true]
            )
            try await sdk.setProposalResult(paymentRequestRecord(counterparty: publicKey, role: .payee))
            let service = PaykitPaymentRequestService(
                sdk: sdk, now: { now }, isPrivatePaymentPublishingEnabled: { true }, logWarning: { _ in }
            )

            do {
                if isSubscription {
                    _ = try await service.proposeSubscription(
                        PaykitSubscriptionDraft(
                            amountSats: 1000, name: "Support", description: "", frequency: .month,
                            expiresAt: expiresAt, iconData: nil
                        ),
                        to: target, savedPublicKeys: [unrelatedKey], expectedIdentity: expectedIdentity,
                        validateBeforeProposing: {}
                    )
                } else {
                    _ = try await service.propose(
                        PaykitPaymentRequestDraft(amountSats: 1000, note: "Support", expiresAt: expiresAt),
                        to: target, savedPublicKeys: [unrelatedKey], expectedIdentity: expectedIdentity
                    )
                }
                XCTFail("Expected the unsaved target to be rejected, subscription: \(isSubscription)")
            } catch {
                XCTAssertEqual(error as? PaykitPaymentRequestError, .requestUnavailable)
            }

            let lookups = await sdk.capabilityLookupPublicKeys
            XCTAssertTrue(lookups.isEmpty)
            let snapshot = await sdk.snapshot()
            XCTAssertTrue(snapshot.proposedRequests.isEmpty)
            XCTAssertEqual(snapshot.uploadCount, 0)
        }
    }

    func testProposeRemainsCreatedWhenImmediateDeliveryFails() async throws {
        let publicKey = "pubky\(String(repeating: "y", count: 52))"
        let expiresAt = Date(timeIntervalSince1970: 1_900_000_000)
        for cancelled in [false, true] {
            let sdk = PaymentRequestSdkMock(records: [])
            await sdk.configureRecipients(
                peers: [linkedPeer(counterparty: publicKey, state: .linked)],
                requestCapabilitiesByPublicKey: [publicKey: true]
            )
            try await sdk.setProposalResult(paymentRequestRecord(
                id: "outgoing",
                counterparty: publicKey,
                role: .payee,
                expiresAt: timestamp(expiresAt),
                proposalOutboundMessageId: 7
            ))
            if cancelled {
                await sdk.cancelNextProcess()
            } else {
                await sdk.failNextProcess()
            }
            let manager = paymentRequestManager(sdk: sdk)
            await manager.refreshEligibleTargets(savedPublicKeys: [publicKey])

            let request = try await manager.propose(
                PaykitPaymentRequestDraft(amountSats: 1, note: "", expiresAt: expiresAt),
                to: XCTUnwrap(manager.eligibleTargets.first)
            )

            XCTAssertEqual(request.deliveryStatus, .queued)
            XCTAssertEqual(manager.outgoingRequests.map(\.paymentRequestId), ["outgoing"])
            let snapshot = await sdk.snapshot()
            XCTAssertEqual(snapshot.proposedRequests.count, 1)
            XCTAssertEqual(snapshot.processCallCount, 0)
            XCTAssertEqual(snapshot.processedCounterparties, [publicKey])
            XCTAssertEqual(snapshot.paymentRequestListCallCount, cancelled ? 0 : 1)
        }
    }

    func testProposeRevalidatesTargetBeforeEnqueueing() async throws {
        let publicKey = "pubky\(String(repeating: "y", count: 52))"
        let expiresAt = Date(timeIntervalSince1970: 1_900_000_000)
        let sdk = PaymentRequestSdkMock(records: [])
        await sdk.configureRecipients(
            peers: [linkedPeer(counterparty: publicKey, state: .linked)],
            requestCapabilitiesByPublicKey: [publicKey: true]
        )
        try await sdk.setProposalResult(paymentRequestRecord(
            id: "outgoing",
            counterparty: publicKey,
            role: .payee,
            expiresAt: timestamp(expiresAt)
        ))
        let manager = paymentRequestManager(sdk: sdk)
        await manager.refreshEligibleTargets(savedPublicKeys: [publicKey])
        let target = try XCTUnwrap(manager.eligibleTargets.first)

        await sdk.configureRecipients(peers: [], requestCapabilitiesByPublicKey: [publicKey: true])

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
            peers: [linkedPeer(counterparty: publicKey, state: .linked)],
            requestCapabilitiesByPublicKey: [publicKey: true]
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
            peers: [linkedPeer(counterparty: publicKey, state: .linked)],
            requestCapabilitiesByPublicKey: [publicKey: true]
        )
        try await sdk.setProposalResult(paymentRequestRecord(
            id: "outgoing",
            counterparty: publicKey,
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
            peers: [linkedPeer(counterparty: publicKey, state: .linked)],
            requestCapabilitiesByPublicKey: [publicKey: true]
        )
        try await sdk.setProposalResult(paymentRequestRecord(
            id: "outgoing",
            counterparty: publicKey,
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
            peers: [linkedPeer(counterparty: publicKey, state: .linked)],
            requestCapabilitiesByPublicKey: [publicKey: true]
        )
        try await sdk.setProposalResult(paymentRequestRecord(
            id: "outgoing",
            counterparty: publicKey,
            role: .payee,
            expiresAt: timestamp(expiresAt),
            proposalOutboundMessageId: messageId
        ))
        await sdk.setProcessReports([
            OutboundPrivateCounterpartySendReport(
                counterparty: publicKey,
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
            scheduleAcceptedRequestDelivery: { _ in },
            service: PaykitPaymentRequestService(sdk: sdk, logWarning: { _ in }),
            presentationStore: store,
            acceptanceStore: PaymentRequestPresentationMemoryStore(),
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
        scheduleAcceptedRequestDelivery: @escaping @MainActor (String) async -> Void = { _ in },
        paymentActivity: PaykitPaymentActivity? = nil,
        clock: PaymentRequestTestClock = PaymentRequestTestClock(Date()),
        subscriptionClock: PaymentRequestTestClock? = nil,
        subscriptionStateStore: PaymentRequestSubscriptionStateMemoryStore = PaymentRequestSubscriptionStateMemoryStore(),
        subscriptionNotificationScheduler: PaykitSubscriptionNotificationScheduler = PaykitSubscriptionNotificationScheduler(),
        isPrivatePaymentPublishingEnabled: Bool = true,
        completedPaymentProofKinds: [PaykitPaymentRequest.ID: PaykitPaymentProofKind] = [:],
        inFlightPaymentRequestIds: Set<PaykitPaymentRequest.ID> = [],
        protectedRequestIdsForSubscriptionCancellation: Set<PaykitPaymentRequest.ID> = [],
        presentationStore: PaymentRequestPresentationMemoryStore = PaymentRequestPresentationMemoryStore(),
        acceptanceStore: PaymentRequestPresentationMemoryStore? = nil,
        acceptedRecords: [PaymentRequestRecord] = []
    ) -> PaykitPaymentRequestManager {
        let now: @Sendable () -> Date = { clock.now() }
        let acceptanceStore = acceptanceStore ?? PaymentRequestPresentationMemoryStore(ids: Set(acceptedRecords.map {
            PaykitPaymentRequest.ID(paymentRequestId: $0.paymentRequestId, counterparty: $0.counterparty)
        }))
        let subscriptionNow: (@Sendable () -> Date)? = subscriptionClock.map { subscriptionClock in { subscriptionClock.now() } }
        let manager = PaykitPaymentRequestManager(
            scheduleAcceptedRequestDelivery: scheduleAcceptedRequestDelivery,
            paymentActivity: paymentActivity ?? PaykitPaymentActivity(),
            service: PaykitPaymentRequestService(
                sdk: sdk,
                now: now,
                subscriptionNow: subscriptionNow,
                isPrivatePaymentPublishingEnabled: { isPrivatePaymentPublishingEnabled },
                logWarning: { _ in }
            ),
            presentationStore: presentationStore,
            acceptanceStore: acceptanceStore,
            subscriptionStateStore: subscriptionStateStore,
            subscriptionNotificationScheduler: subscriptionNotificationScheduler,
            completedPaymentProofKinds: { _ in completedPaymentProofKinds },
            inFlightPaymentRequestIds: { _ in inFlightPaymentRequestIds },
            protectedRequestIdsForSubscriptionCancellation: { _, _ in protectedRequestIdsForSubscriptionCancellation },
            now: now,
            subscriptionNow: subscriptionNow,
            retryNow: { clock.retryNow() },
            isAvailable: { true },
            logWarning: { _ in }
        )
        manager.activate(identity: "pubky\(String(repeating: "z", count: 52))")
        return manager
    }

    private func weeklySubscription(
        id: String = "550e8400-e29b-41d4-a716-446655440000",
        unit: String = "week",
        endsAt: String? = nil
    ) throws -> PaykitSubscription {
        let recurrence = PaymentRequestRecurrence(
            every: 1,
            unit: unit,
            startsAt: "2027-01-01T08:00:00Z",
            anchor: "2027-01-01T08:00:00Z",
            endsAt: endsAt
        )
        return try XCTUnwrap(PaykitSubscription(record: paymentRequestRecord(
            id: id,
            state: .activeRecurring,
            recurrence: recurrence
        )))
    }

    private func paymentRequestRecord(
        id: String = "550e8400-e29b-41d4-a716-446655440000",
        counterparty: String = "pubkypayee",
        state: PaymentRequestLifecycleState = .proposed,
        role: PaymentRequestLocalRole? = .payer,
        amount: String = "0.001",
        asset: String = "btc",
        expiresAt: String? = nil,
        paymentDeadline: PaymentDeadline? = nil,
        recurrence: PaymentRequestRecurrence? = nil,
        endpoints: [String] = [PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue],
        paymentEndpoints: [String: String]? = nil,
        metadata: String = "{}",
        lastEventAt: String = "2027-01-15T08:00:00Z",
        proposalOutboundMessageId: UInt64? = nil,
        proposalOutboundStatus: OutboundPrivateMessageStatus? = nil,
        acceptedEventId: String? = nil,
        rejectedEventId: String? = nil,
        canceledEventId: String? = nil,
        paymentProofs: [PaymentProofRecord] = []
    ) throws -> PaymentRequestRecord {
        try PaymentRequestRecord(
            counterparty: counterparty,
            paymentRequestId: id,
            localRole: role,
            state: state,
            proposalStreamItemId: 1,
            proposalOutboundMessageId: proposalOutboundMessageId,
            proposalOutboundStatus: proposalOutboundStatus,
            proposalEventId: "650e8400-e29b-41d4-a716-446655440000",
            proposalAppId: "bitkit",
            payerAppId: nil,
            executionClaimAppId: nil,
            terms: PaymentRequestTerms(
                amount: PaymentRequestAmount(value: amount, asset: asset),
                paymentReference: PaymentReference(text: "invoice-123"),
                proposalExpiresAt: expiresAt,
                recurrence: recurrence,
                acceptedPaymentEndpointIdentifiers: endpoints,
                paymentEndpoints: paymentEndpoints,
                requiredAppId: "bitkit",
                conversion: nil,
                paymentDeadline: paymentDeadline,
                metadata: PrivateJsonObject(text: metadata)
            ),
            acceptedEventId: acceptedEventId,
            acceptedOutboundStatus: nil,
            rejectedEventId: rejectedEventId,
            rejectedOutboundStatus: nil,
            canceledEventId: canceledEventId,
            canceledOutboundStatus: nil,
            conversionQuotes: [],
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
            paymentAppId: "bitkit",
            paymentEndpointIdentifier: endpoint,
            allowanceId: nil,
            conversionQuoteId: nil,
            proof: PrivateJsonObject(text: "{\"data\":\"proof\",\"type\":\"\(kind.rawValue)\"}"),
            recordedAt: "2027-01-15T08:01:00Z"
        )
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func linkedPeer(counterparty: String, state: LinkedPeerState) -> LinkedPeerRecord {
        LinkedPeerRecord(
            counterparty: counterparty,
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

private final class PaymentRequestPresentationMemoryStore: PaykitPaymentRequestIdStoring {
    private var states: [String: Set<PaykitPaymentRequest.ID>] = [:]
    var shouldFailSave = false
    var shouldFailLoad = false

    init(ids: Set<PaykitPaymentRequest.ID> = []) {
        states["pubky\(String(repeating: "z", count: 52))"] = ids
    }

    func load(identity: String) throws -> Set<PaykitPaymentRequest.ID> {
        if shouldFailLoad { throw PaymentRequestSdkMockError.process }
        return states[identity] ?? []
    }

    func save(_ ids: Set<PaykitPaymentRequest.ID>, identity: String) throws {
        if shouldFailSave { throw PaymentRequestSdkMockError.process }
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

private final class PaymentRequestSubscriptionStateMemoryStore: PaykitSubscriptionStateStoring {
    private var states: [String: PaykitSubscriptionState] = [:]
    var shouldFailLoad = false
    var shouldFailSave = false
    private(set) var saveCallCount = 0

    func load(identity: String) throws -> PaykitSubscriptionState {
        if shouldFailLoad {
            throw PaymentRequestSdkMockError.preparation
        }
        return states[identity] ?? PaykitSubscriptionState()
    }

    func save(_ subscriptionState: PaykitSubscriptionState, identity: String) throws {
        if shouldFailSave {
            throw PaymentRequestSdkMockError.preparation
        }
        saveCallCount += 1
        states[identity] = subscriptionState
    }
}

private actor PaymentRequestSdkMock: PaykitPaymentRequestSdkHandling, PaykitPaymentProofSdkHandling {
    private(set) var operationPriorities: [String: [PaykitSdkOperationLock.Priority]] = [:]
    private var activeIdentity = "pubky\(String(repeating: "z", count: 52))"
    private var records: [PaymentRequestRecord]
    private var incomingRecords: [PaymentRequestRecord] = []
    private var paymentRequestListCallCount = 0
    private var paymentRequestListError: Error?
    private var peerRecords: [LinkedPeerRecord] = []
    private var requestCapabilitiesByPublicKey: [String: Bool] = [:]
    private var liveSessionAvailable = true
    private var linkedPeersError: PaymentRequestSdkMockError?
    private var linkedPeersCallCount = 0
    private(set) var capabilityLookupPublicKeys: [String] = []
    private(set) var activeCapabilityLookups = 0
    private(set) var maxConcurrentCapabilityLookups = 0
    private var capabilityLookupGate: (@Sendable (String) async -> Void)?
    private var failingCapabilityKeys: Set<String> = []
    private var capabilityLookupPriorities: [PaykitPublicReadPriority] = []
    private var proposalResult: PaymentRequestRecord?
    private var uploadCount = 0
    private var shouldPauseNextUpload = false
    private var isUploadPaused = false
    private var uploadContinuation: CheckedContinuation<Void, Never>?
    private var processCallCount = 0
    private var processedCounterparties: [String] = []
    private var receiveCallCount = 0
    private var processFailuresRemaining = 0
    private var processCancellationsRemaining = 0
    private var processReports: [OutboundPrivateCounterpartySendReport] = []
    private var shouldPauseNextProcess = false
    private var pausedProcessCounterparty: String?
    private var isProcessPaused = false
    private var processContinuation: CheckedContinuation<Void, Never>?
    private var receiveError: PaymentRequestSdkMockError?
    private var receiveReports: [PrivateStreamCounterpartyIntakeReport] = []
    private var acceptedRequests: [PaymentRequestInvocation] = []
    private var rejectedRequests: [PaymentRequestInvocation] = []
    private var acceptFailuresAfterRemoval = 0
    private var acceptanceResponseError: Error?

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
        try await processPendingPrivateMessages(priority: .ordered)
    }

    func processPendingPrivateMessages(priority: PaykitSdkOperationLock.Priority) async throws -> [OutboundPrivateCounterpartySendReport] {
        operationPriorities["pending", default: []].append(priority)
        processCallCount += 1
        try await processMessages()
        return processReports
    }

    func processOutboundPrivateMessages(counterparty: String) async throws -> OutboundPrivateSendReport {
        processedCounterparties.append(counterparty)
        try await processMessages(counterparty: counterparty)
        return processReports.first { $0.counterparty == counterparty }?.report ?? OutboundPrivateSendReport(
            attempted: [], sent: [], failed: [], reservationCleanupFailures: [], recoveryMarkerFailures: []
        )
    }

    func processOutboundPrivateMessages(counterparty: String, priority: PaykitSdkOperationLock.Priority) async throws -> OutboundPrivateSendReport {
        operationPriorities["delivery", default: []].append(priority)
        return try await processOutboundPrivateMessages(counterparty: counterparty)
    }

    private func processMessages(counterparty: String? = nil) async throws {
        if shouldPauseNextProcess,
           counterparty == nil || pausedProcessCounterparty == nil || counterparty == pausedProcessCounterparty
        {
            shouldPauseNextProcess = false
            isProcessPaused = true
            await withCheckedContinuation { processContinuation = $0 }
            isProcessPaused = false
        }
        if processCancellationsRemaining > 0 {
            processCancellationsRemaining -= 1
            throw CancellationError()
        }
        guard processFailuresRemaining > 0 else { return }
        processFailuresRemaining -= 1
        throw PaymentRequestSdkMockError.process
    }

    func receivePrivateMessagesFromLinkedPeers(priority: PaykitSdkOperationLock.Priority) throws -> [PrivateStreamCounterpartyIntakeReport] {
        operationPriorities["receive", default: []].append(priority)
        receiveCallCount += 1
        if let receiveError {
            throw receiveError
        }
        records.append(contentsOf: incomingRecords)
        incomingRecords = []
        return receiveReports
    }

    func paymentRequests() async -> [PaymentRequestRecord] {
        await sharedPaymentRequests().filter(PaykitSdkService.isBitkitPaymentRequest)
    }

    func sharedPaymentRequests() async -> [PaymentRequestRecord] {
        paymentRequestListCallCount += 1
        let snapshot = records
        guard shouldPauseNextPaymentRequestList else { return snapshot }

        shouldPauseNextPaymentRequestList = false
        isPaymentRequestListPaused = true
        await withCheckedContinuation { paymentRequestListContinuation = $0 }
        isPaymentRequestListPaused = false
        return snapshot
    }

    func sharedPaymentRequests(priority: PaykitSdkOperationLock.Priority) async -> [PaymentRequestRecord] {
        operationPriorities["requests", default: []].append(priority)
        return await sharedPaymentRequests()
    }

    func sharedPaymentRequests(expectedIdentity: String) async throws -> [PaymentRequestRecord] {
        guard PubkyPublicKeyFormat.matches(activeIdentity, expectedIdentity) else {
            throw PaykitPaymentRequestError.requestUnavailable
        }
        if let paymentRequestListError { throw paymentRequestListError }
        return await sharedPaymentRequests()
    }

    func setPaymentRequestListError(_ error: Error) {
        paymentRequestListError = error
    }

    func identityStatus() -> IdentityStatus? {
        IdentityStatus(publicKey: activeIdentity, capability: liveSessionAvailable ? .privateLinkCapable : .signedOut)
    }

    func identityStatus(priority: PaykitSdkOperationLock.Priority) -> IdentityStatus? {
        operationPriorities["identity", default: []].append(priority)
        return identityStatus()
    }

    func submitPaymentProof(
        counterparty _: String,
        paymentRequestId _: String,
        proof _: PaymentProofSubmission
    ) throws -> PaymentRequestRecord {
        XCTFail("Failure cleanup must not submit a payment proof")
        throw PaymentRequestSdkMockError.process
    }

    func linkedPeers() async throws -> [LinkedPeerRecord] {
        linkedPeersCallCount += 1
        let error = linkedPeersError
        let snapshot = peerRecords
        if shouldPauseNextLinkedPeers {
            shouldPauseNextLinkedPeers = false
            isLinkedPeersPaused = true
            await withCheckedContinuation { linkedPeersContinuation = $0 }
            isLinkedPeersPaused = false
        }
        if let error { throw error }
        return snapshot
    }

    func linkedPeers(priority: PaykitSdkOperationLock.Priority) async throws -> [LinkedPeerRecord] {
        operationPriorities["peers", default: []].append(priority)
        return try await linkedPeers()
    }

    func canReceivePaymentRequests(publicKey: String, priority: PaykitPublicReadPriority) async throws -> Bool {
        capabilityLookupPublicKeys.append(publicKey)
        capabilityLookupPriorities.append(priority)
        activeCapabilityLookups += 1
        maxConcurrentCapabilityLookups = max(maxConcurrentCapabilityLookups, activeCapabilityLookups)
        defer { activeCapabilityLookups -= 1 }
        await capabilityLookupGate?(publicKey)
        if failingCapabilityKeys.contains(publicKey) {
            throw PaymentRequestSdkMockError.receive
        }
        return requestCapabilitiesByPublicKey[publicKey] ?? false
    }

    func pauseNextUpload() {
        shouldPauseNextUpload = true
    }

    func uploadIsPaused() -> Bool {
        isUploadPaused
    }

    func resumeUpload() {
        uploadContinuation?.resume()
        uploadContinuation = nil
    }

    func uploadProfileAvatar(bytes _: Data, contentType _: String, expectedIdentity: String?) async throws -> String {
        if shouldPauseNextUpload {
            shouldPauseNextUpload = false
            isUploadPaused = true
            await withCheckedContinuation { uploadContinuation = $0 }
            isUploadPaused = false
        }
        guard expectedIdentity == nil || PubkyPublicKeyFormat.matches(activeIdentity, expectedIdentity ?? "") else {
            throw PaykitPaymentRequestError.requestUnavailable
        }
        uploadCount += 1
        return "pubky://\(activeIdentity)/pub/paykit/blobs/subscription-icon.jpg"
    }

    func proposePaymentRequest(
        counterparty: String,
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
        result.terms = terms
        records.append(result)
        proposedRequests.append(ProposedPaymentRequestInvocation(
            counterparty: counterparty,
            amount: terms.amount.value,
            asset: terms.amount.asset,
            expiresAt: terms.proposalExpiresAt,
            recurrence: terms.recurrence,
            endpointIdentifiers: terms.acceptedPaymentEndpointIdentifiers,
            metadata: terms.metadata.exportText()
        ))
        return result
    }

    func claimPaymentRequestForExecution(counterparty: String, paymentRequestId: String) throws -> PaymentRequestRecord {
        guard let index = records.firstIndex(where: {
            $0.counterparty == counterparty && $0.paymentRequestId == paymentRequestId
        }), records[index].executionClaimAppId == nil || records[index].executionClaimAppId == "bitkit" else {
            throw PaymentRequestSdkMockError.requestMissing
        }
        records[index].executionClaimAppId = "bitkit"
        return records[index]
    }

    func acceptPaymentRequest(
        counterparty: String,
        paymentRequestId: String
    ) async throws -> PaymentRequestRecord {
        if shouldPauseNextAccept {
            shouldPauseNextAccept = false
            isAcceptPaused = true
            await withCheckedContinuation { acceptContinuation = $0 }
            isAcceptPaused = false
        }

        let record: PaymentRequestRecord
        guard records.contains(where: {
            $0.counterparty == counterparty && $0.paymentRequestId == paymentRequestId && $0.state == .proposed
        }) else { throw PaymentRequestSdkMockError.requestMissing }
        if let index = records.firstIndex(where: {
            $0.counterparty == counterparty &&
                $0.paymentRequestId == paymentRequestId &&
                $0.terms?.recurrence != nil
        }) {
            records[index].state = .activeRecurring
            record = records[index]
        } else {
            record = try removeRecord(
                counterparty: counterparty,
                id: paymentRequestId
            )
        }
        if let acceptanceResponseError { throw acceptanceResponseError }
        if acceptFailuresAfterRemoval > 0 {
            acceptFailuresAfterRemoval -= 1
            throw PaymentRequestSdkMockError.process
        }
        acceptedRequests.append(PaymentRequestInvocation(
            counterparty: counterparty,
            paymentRequestId: paymentRequestId
        ))
        return record
    }

    func rejectPaymentRequest(
        counterparty: String,
        paymentRequestId: String,
        reason _: String?
    ) throws -> PaymentRequestRecord {
        let record = try removeRecord(
            counterparty: counterparty,
            id: paymentRequestId
        )
        if rejectFailuresAfterRemoval > 0 {
            rejectFailuresAfterRemoval -= 1
            throw PaymentRequestSdkMockError.process
        }
        rejectedRequests.append(PaymentRequestInvocation(
            counterparty: counterparty,
            paymentRequestId: paymentRequestId
        ))
        return record
    }

    func cancelPaymentRequest(
        counterparty: String,
        paymentRequestId: String,
        reason _: String?
    ) throws -> PaymentRequestRecord {
        try removeRecord(
            counterparty: counterparty,
            id: paymentRequestId
        )
    }

    func failNextProcess() {
        processFailuresRemaining += 1
    }

    func setAcceptanceResponseError(_ error: Error) {
        acceptanceResponseError = error
    }

    func pauseNextProcess(for counterparty: String? = nil) {
        shouldPauseNextProcess = true
        pausedProcessCounterparty = counterparty
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

    func setIncomingRecords(_ records: [PaymentRequestRecord]) {
        incomingRecords = records
    }

    func configureRecipients(
        peers: [LinkedPeerRecord],
        requestCapabilitiesByPublicKey: [String: Bool]
    ) {
        peerRecords = peers
        self.requestCapabilitiesByPublicKey = requestCapabilitiesByPublicKey
    }

    func setLiveSessionAvailable(_ value: Bool) {
        liveSessionAvailable = value
    }

    func linkedPeersCalls() -> Int {
        linkedPeersCallCount
    }

    func capabilityLookups() -> Int {
        capabilityLookupPublicKeys.count
    }

    func setCapabilityLookupGate(_ gate: @escaping @Sendable (String) async -> Void) {
        capabilityLookupGate = gate
    }

    func capabilityReadPriorities() -> [PaykitPublicReadPriority] {
        capabilityLookupPriorities
    }

    func setLinkedPeersError(_ error: PaymentRequestSdkMockError?) {
        linkedPeersError = error
    }

    func setCapabilityLookupFailing(_ isFailing: Bool, for publicKey: String) {
        if isFailing {
            failingCapabilityKeys.insert(publicKey)
        } else {
            failingCapabilityKeys.remove(publicKey)
        }
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

    func setReceiveReports(_ reports: [PrivateStreamCounterpartyIntakeReport]) {
        receiveReports = reports
    }

    func snapshot() -> PaymentRequestSdkSnapshot {
        PaymentRequestSdkSnapshot(
            uploadCount: uploadCount,
            processCallCount: processCallCount,
            processedCounterparties: processedCounterparties,
            receiveCallCount: receiveCallCount,
            paymentRequestListCallCount: paymentRequestListCallCount,
            acceptedRequests: acceptedRequests,
            rejectedRequests: rejectedRequests,
            proposedRequests: proposedRequests
        )
    }

    private func removeRecord(
        counterparty: String,
        id: String
    ) throws -> PaymentRequestRecord {
        guard let index = records.firstIndex(where: {
            $0.counterparty == counterparty &&
                $0.paymentRequestId == id
        }) else {
            throw PaymentRequestSdkMockError.requestMissing
        }
        return records.remove(at: index)
    }
}

private struct PaymentRequestSdkSnapshot {
    let uploadCount: Int
    let processCallCount: Int
    let processedCounterparties: [String]
    let receiveCallCount: Int
    let paymentRequestListCallCount: Int
    let acceptedRequests: [PaymentRequestInvocation]
    let rejectedRequests: [PaymentRequestInvocation]
    let proposedRequests: [ProposedPaymentRequestInvocation]
}

private struct ProposedPaymentRequestInvocation {
    let counterparty: String
    let amount: String
    let asset: String
    let expiresAt: String?
    let recurrence: PaymentRequestRecurrence?
    let endpointIdentifiers: [String]
    let metadata: String
}

private struct PaymentRequestInvocation: Equatable {
    let counterparty: String
    let paymentRequestId: String
}

private enum PaymentRequestSdkMockError: Error, Equatable {
    case linkedPeers
    case preparation
    case process
    case receive
    case requestMissing
}

private final class PaymentRequestTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    private var retryInstant = ContinuousClock.now
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
        retryInstant = retryInstant.advanced(by: .seconds(interval))
    }

    func shiftWallClock(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        date = date.addingTimeInterval(interval)
    }

    func retryNow() -> ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return retryInstant
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
    private var shouldPauseNextPendingRequests = false
    private var pendingRequestsContinuation: CheckedContinuation<Void, Never>?

    var isAddPaused: Bool {
        addContinuation != nil
    }

    var pendingIdentifiers: Set<String> {
        Set(requests.keys)
    }

    func calendarTriggers() -> [String: DateComponents] {
        requests.compactMapValues { ($0.trigger as? UNCalendarNotificationTrigger)?.dateComponents }
    }

    var isPendingRequestsPaused: Bool {
        pendingRequestsContinuation != nil
    }

    func pauseNextAdd() {
        shouldPauseNextAdd = true
    }

    func pauseNextPendingRequests() {
        shouldPauseNextPendingRequests = true
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        if shouldPauseNextPendingRequests {
            shouldPauseNextPendingRequests = false
            await withCheckedContinuation { pendingRequestsContinuation = $0 }
        }
        return Array(requests.values)
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

    func resumePendingRequests() {
        pendingRequestsContinuation?.resume()
        pendingRequestsContinuation = nil
    }
}

private final class PaymentRequestIntakeError: PrivateOperationError, @unchecked Sendable {
    override func redactedContext() -> String {
        "transport failure"
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

private actor HardwarePaymentProofMemoryStore: PaykitPaymentProofStoring {
    private var proofs: [PendingPaykitPaymentProof] = []
    private var shouldFailSave = false

    func failNextSave() {
        shouldFailSave = true
    }

    func load() -> [PendingPaykitPaymentProof] {
        proofs
    }

    func save(_ proofs: [PendingPaykitPaymentProof]) throws {
        if shouldFailSave {
            shouldFailSave = false
            throw NSError(domain: "proof-store-fixture", code: 1)
        }
        self.proofs = proofs
    }
}
