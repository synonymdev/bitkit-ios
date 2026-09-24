import Foundation
import Paykit

struct PaykitPaymentStateBackup: Codable {
    let subscriptions: [String: Subscription]
    let pendingProofs: [Proof]

    struct RequestID: Codable {
        let paymentRequestId: String
        let counterparty: String
        let counterpartyReceiverPath: String
        let billingPeriodStartsAt: String?

        init(_ id: PaykitPaymentRequest.ID, billingPeriod: PaykitBillingPeriod?) {
            paymentRequestId = id.paymentRequestId
            counterparty = id.counterparty
            counterpartyReceiverPath = id.counterpartyReceiverPath
            billingPeriodStartsAt = billingPeriod?.sdkValue.startsAt
        }

        func restored(billingPeriod: PaykitBillingPeriod?) -> PaykitPaymentRequest.ID {
            PaykitPaymentRequest.ID(
                paymentRequestId: paymentRequestId,
                counterparty: counterparty,
                counterpartyReceiverPath: counterpartyReceiverPath,
                billingPeriodStartsAt: billingPeriod?.startsAt
            )
        }
    }

    struct Subscription: Codable {
        struct Acceptance: Codable {
            let id: PaykitSubscription.ID
            let acceptedAt: String
        }

        let acceptances: [Acceptance]
        let presentedProposalIds: Set<PaykitSubscription.ID>

        init(_ state: PaykitSubscriptionState) {
            acceptances = state.acceptedAt.map { Acceptance(id: $0.key, acceptedAt: PaykitPreciseInstant(date: $0.value).timestamp) }
            presentedProposalIds = state.presentedProposalIds
        }

        func restored() throws -> PaykitSubscriptionState {
            var acceptedAt: [PaykitSubscription.ID: Date] = [:]
            for acceptance in acceptances {
                acceptedAt[acceptance.id] = try parseTimestamp(acceptance.acceptedAt)
            }
            return PaykitSubscriptionState(
                acceptedAt: acceptedAt,
                presentedProposalIds: presentedProposalIds
            )
        }
    }

    struct Proof: Codable {
        struct Period: Codable {
            let startsAt: String
            let endsAt: String
        }

        let identity: String
        let requestId: RequestID
        let paymentEndpointIdentifier: String
        let kind: PaykitPaymentProofKind
        let paymentStarted: Bool
        let paymentIdentifier: String?
        let proofData: String?
        let billingPeriod: Period?
        let onchainAddress: String?
        let onchainAmountSats: UInt64?
        let onchainWalletId: String?
        let onchainMatchingTransactionIdsBeforeAttempt: Set<String>

        init(_ proof: PendingPaykitPaymentProof) {
            identity = proof.identity
            requestId = RequestID(proof.requestId, billingPeriod: proof.billingPeriod)
            paymentEndpointIdentifier = proof.paymentEndpointIdentifier
            kind = proof.kind
            paymentStarted = proof.paymentStarted
            paymentIdentifier = proof.paymentIdentifier
            proofData = proof.proofData
            billingPeriod = proof.billingPeriod.map { Period(startsAt: $0.sdkValue.startsAt, endsAt: $0.sdkValue.endsAt) }
            onchainAddress = proof.onchainAddress
            onchainAmountSats = proof.onchainAmountSats
            onchainWalletId = proof.onchainWalletId
            onchainMatchingTransactionIdsBeforeAttempt = proof.onchainMatchingTransactionIdsBeforeAttempt ?? []
        }

        func restored() throws -> PendingPaykitPaymentProof {
            let period = try billingPeriod.map { value in
                guard let period = PaykitBillingPeriod(sdkPeriod: BillingPeriod(startsAt: value.startsAt, endsAt: value.endsAt)) else {
                    throw invalidBackup("Invalid Paykit billing period")
                }
                return period
            }
            return PendingPaykitPaymentProof(
                identity: identity,
                requestId: requestId.restored(billingPeriod: period),
                paymentEndpointIdentifier: paymentEndpointIdentifier,
                kind: kind,
                billingPeriod: period,
                paymentStarted: paymentStarted,
                paymentIdentifier: paymentIdentifier,
                proofData: proofData,
                onchainAddress: onchainAddress,
                onchainAmountSats: onchainAmountSats,
                onchainWalletId: onchainWalletId,
                onchainMatchingTransactionIdsBeforeAttempt: onchainMatchingTransactionIdsBeforeAttempt
            )
        }
    }

    private static func parseTimestamp(_ value: String) throws -> Date {
        guard let instant = PaykitPreciseInstant(timestamp: value) else {
            throw invalidBackup("Invalid Paykit timestamp")
        }
        return instant.date
    }

    private static func invalidBackup(_ message: String) -> NSError {
        NSError(domain: "BackupService", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
