import BitkitCore
import Foundation
import LDKNode
import UIKit

// MARK: - Invoice Rotation

extension PrivatePaykitService {
    func currentOrRotatedInvoice(for publicKey: String, wallet: WalletViewModel, generation: UInt64) async throws -> StoredInvoice {
        if let invoice = await reusablePrivateInvoice(for: publicKey) {
            return invoice
        }

        let bolt11 = try await createVariableInvoice(wallet)
        try ensureCurrentGeneration(generation)
        if let invoice = await reusablePrivateInvoice(for: publicKey) {
            return invoice
        }

        guard case let .lightning(decodedInvoice) = try await decode(invoice: bolt11) else {
            throw PublicPaykitError.invalidPayload
        }

        let invoice = StoredInvoice(
            bolt11: bolt11,
            paymentHash: decodedInvoice.paymentHash.hex,
            expiresAt: Double(decodedInvoice.timestampSeconds + decodedInvoice.expirySeconds)
        )
        state.contacts[publicKey, default: ContactState()].localInvoice = invoice
        persistState()
        return invoice
    }

    func rememberReceivedInvoicePaymentHash(_ paymentHash: String, publicKey: String) {
        guard !paymentHash.isEmpty else { return }

        var contactState = state.contacts[publicKey, default: ContactState()]
        guard !contactState.receivedInvoicePaymentHashes.contains(paymentHash) else { return }

        contactState.receivedInvoicePaymentHashes.append(paymentHash)
        if contactState.receivedInvoicePaymentHashes.count > Self.maxReceivedInvoicePaymentHashesPerContact {
            contactState
                .receivedInvoicePaymentHashes = Array(contactState.receivedInvoicePaymentHashes
                    .suffix(Self.maxReceivedInvoicePaymentHashesPerContact))
        }
        state.contacts[publicKey] = contactState
        persistState()
    }

    func reusablePrivateInvoice(for publicKey: String) async -> StoredInvoice? {
        guard let invoice = state.contacts[publicKey]?.localInvoice,
              invoice.expiresAt > Date().timeIntervalSince1970 + Self.invoiceRefreshBufferSeconds,
              await !isReceivedInvoiceSettled(paymentHash: invoice.paymentHash),
              case let .lightning(decodedInvoice) = try? await decode(invoice: invoice.bolt11),
              !decodedInvoice.isExpired,
              decodedInvoice.amountSatoshis == 0
        else {
            return nil
        }

        return invoice
    }

    @MainActor
    func walletHasUsableChannels(_ wallet: WalletViewModel) -> Bool {
        wallet.hasUsableChannels
    }

    @MainActor
    func canPublishPrivateEndpoints(wallet: WalletViewModel) -> Bool {
        UserDefaults.standard.bool(forKey: Self.publishingEnabledKey) &&
            UIApplication.shared.applicationState == .active &&
            wallet.walletExists == true &&
            wallet.nodeLifecycleState == .running
    }

    @MainActor
    func createVariableInvoice(_ wallet: WalletViewModel) async throws -> String {
        try await wallet.createInvoice(amountSats: nil, note: "")
    }

    func settledPrivateInvoicePaymentHashes() async -> [String] {
        let settledHashes = await receivedSettledPaymentHashes()
        return state.contacts.compactMap { _, contactState in
            guard let paymentHash = contactState.localInvoice?.paymentHash,
                  settledHashes.contains(paymentHash)
            else { return nil }

            return paymentHash
        }
    }

    func isReceivedInvoiceSettled(paymentHash: String) async -> Bool {
        await receivedSettledPaymentHashes().contains(paymentHash)
    }

    func receivedSettledPaymentHashes() async -> Set<String> {
        guard let payments = await LightningService.shared.listPayments() else { return [] }

        return Set(
            payments.compactMap { payment in
                guard payment.direction == .inbound,
                      payment.status == .succeeded,
                      case .bolt11 = payment.kind
                else { return nil }

                return payment.id
            }
        )
    }
}
