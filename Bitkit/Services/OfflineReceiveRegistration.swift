import Foundation
import LDKNode
import Observation

@MainActor
@Observable
final class OfflineReceiveRegistration {
    private let payments: @MainActor () async -> [PaymentDetails]?
    private var paymentRevision = UUID()
    private var invoice: OfflineReceiveInvoice?
    private(set) var revision = UUID()

    init(payments: @escaping @MainActor () async -> [PaymentDetails]?) {
        self.payments = payments
    }

    func reset() {
        revision = UUID()
        invoice = nil
    }

    func beginPreparation() -> UUID {
        reset()
        return revision
    }

    func paymentReceived(hash: String) {
        paymentRevision = UUID()
        if invoice?.paymentHash == hash { invoice = nil }
    }

    func contains(_ invoice: OfflineReceiveInvoice) -> Bool {
        self.invoice == invoice && invoice.expiresAt > .now
    }

    func register(_ invoice: OfflineReceiveInvoice, revision: UUID) async throws {
        while true {
            try Task.checkCancellation()
            guard self.revision == revision else { throw OfflineReceiveError.unavailable }
            let paymentRevision = paymentRevision
            guard let payments = await payments() else { throw OfflineReceiveError.unavailable }
            try Task.checkCancellation()
            guard self.revision == revision, invoice.expiresAt > .now else { throw OfflineReceiveError.unavailable }
            let paid = payments.contains { payment in
                guard payment.direction == .inbound, payment.status == .succeeded,
                      case let .bolt11(hash, _, _, _, _) = payment.kind
                else { return false }
                return hash == invoice.paymentHash
            }
            guard !paid else { throw OfflineReceiveError.unavailable }
            if self.paymentRevision == paymentRevision {
                self.invoice = invoice
                return
            }
        }
    }
}
