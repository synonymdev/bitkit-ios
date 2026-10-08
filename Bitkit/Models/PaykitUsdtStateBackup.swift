import BitkitCore
import Foundation
import Paykit

struct PaykitUsdtStateBackup: Codable {
    let attempts: [Attempt]
    let receipts: [Receipt]

    struct Attempt: Codable {
        let quoteId: String
        let wallet: String
        let identity: String
        let contact: String
        let requestId: PaykitPaymentStateBackup.RequestID?
        let binding: UsdtPaymentProofBinding?
        let billingPeriod: PaykitPaymentStateBackup.Proof.Period?
        let proof: PaykitUsdtPaymentService.Proof?
        let proofQueued: Bool
        let paymentStarted: Bool

        init(_ value: PaykitUsdtPaymentService.Attempt) {
            quoteId = value.quoteId
            wallet = value.wallet
            identity = value.identity
            contact = value.contact
            requestId = value.requestId.map { PaykitPaymentStateBackup.RequestID($0, billingPeriod: value.billingPeriod) }
            binding = value.binding
            billingPeriod = value.billingPeriod.map {
                PaykitPaymentStateBackup.Proof.Period(startsAt: $0.sdkValue.startsAt, endsAt: $0.sdkValue.endsAt)
            }
            proof = value.proof
            proofQueued = value.proofQueued
            paymentStarted = value.paymentStarted
        }

        func restored() throws -> PaykitUsdtPaymentService.Attempt {
            let period = try billingPeriod.map {
                guard let value = PaykitBillingPeriod(sdkPeriod: BillingPeriod(startsAt: $0.startsAt, endsAt: $0.endsAt)) else {
                    throw PaykitPaymentRequestError.requestUnavailable
                }
                return value
            }
            return PaykitUsdtPaymentService.Attempt(
                quoteId: quoteId, wallet: wallet, identity: identity, contact: contact,
                requestId: requestId?.restored(billingPeriod: period), binding: binding, billingPeriod: period,
                proof: proof, proofQueued: proofQueued, paymentStarted: paymentStarted
            )
        }
    }

    struct Receipt: Codable {
        let wallet: String
        let identity: String
        let requestId: PaykitPaymentStateBackup.RequestID
        let paymentId: String
        let proofEventId: String
        let verified: Bool
        let transferId: String
        let amountAtomic: UInt64
        let receivedAtMillis: Int64
        let underpaid: Bool
        let afterExpiry: Bool

        init(_ value: PaykitUsdtPaymentService.Receipt) {
            wallet = value.wallet
            identity = value.identity
            requestId = PaykitPaymentStateBackup.RequestID(
                paymentRequestId: value.requestId.paymentRequestId, counterparty: value.requestId.counterparty,
                billingPeriodStartsAt: value.requestId.billingPeriodStartsAt.map { PaykitPreciseInstant(date: $0).timestamp }
            )
            paymentId = value.paymentId
            proofEventId = value.proofEventId
            verified = value.verified
            transferId = value.transferId
            amountAtomic = value.amount.atomic
            receivedAtMillis = Int64(value.receivedAt.timeIntervalSince1970 * 1000)
            underpaid = value.underpaid
            afterExpiry = value.afterExpiry
        }

        func restored() throws -> PaykitUsdtPaymentService.Receipt {
            let periodStart = try requestId.billingPeriodStartsAt.map {
                guard let instant = PaykitPreciseInstant(timestamp: $0) else { throw PaykitPaymentRequestError.requestUnavailable }
                return instant.date
            }
            return PaykitUsdtPaymentService.Receipt(
                wallet: wallet, identity: identity,
                requestId: .init(paymentRequestId: requestId.paymentRequestId, counterparty: requestId.counterparty,
                                 billingPeriodStartsAt: periodStart),
                paymentId: paymentId, proofEventId: proofEventId, verified: verified, transferId: transferId,
                amount: PaykitAmount(asset: .usdt, atomic: amountAtomic),
                receivedAt: Date(timeIntervalSince1970: Double(receivedAtMillis) / 1000), underpaid: underpaid, afterExpiry: afterExpiry
            )
        }
    }
}
