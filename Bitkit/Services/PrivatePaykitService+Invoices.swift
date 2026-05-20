import BitkitCore
import Foundation
import LDKNode
import UIKit

// MARK: - Invoice Rotation

extension PrivatePaykitService {
    func currentOrRotatedInvoice(for publicKey: String, wallet: WalletViewModel, generation: UInt64,
                                 forceRefresh: Bool = false) async throws -> StoredInvoice
    {
        if !forceRefresh, let invoice = await reusablePrivateInvoice(for: publicKey) {
            return invoice
        }

        let bolt11 = try await createVariableInvoice(wallet)
        try ensureCurrentGeneration(generation)
        if !forceRefresh, let invoice = await reusablePrivateInvoice(for: publicKey) {
            return invoice
        }

        guard case let .lightning(decodedInvoice) = try await decode(invoice: bolt11) else {
            throw PublicPaykitError.invalidPayload
        }
        guard PublicPaykitService.hasLightningRouteHints(bolt11: bolt11) else {
            throw PrivatePaykitError.routeHintsUnavailable
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
              decodedInvoice.amountSatoshis == 0,
              PublicPaykitService.hasLightningRouteHints(bolt11: invoice.bolt11)
        else {
            return nil
        }

        return invoice
    }

    func paymentHash(forBolt11 bolt11: String) async -> String? {
        guard case let .lightning(decodedInvoice) = try? await decode(invoice: bolt11) else {
            return nil
        }

        return decodedInvoice.paymentHash.hex
    }

    func hasAttemptedOutboundBolt11Payment(paymentHash: String) async -> Bool {
        await attemptedOutboundBolt11PaymentHashes().contains(paymentHash)
    }

    @MainActor
    func walletHasUsableChannels(_ wallet: WalletViewModel) -> Bool {
        wallet.hasUsableChannels
    }

    func shouldRetryMissingPrivateLightningEndpoint(for publicKey: String, wallet: WalletViewModel) async -> Bool {
        guard PublicPaykitService.isLightningPaymentOptionEnabled(),
              await walletHasUsableChannels(wallet)
        else {
            return false
        }

        return await reusablePrivateInvoice(for: publicKey) == nil
    }

    @MainActor
    func canPublishPrivateEndpoints(wallet: WalletViewModel) async -> Bool {
        guard PaykitFeatureFlags.isUIEnabled,
              UserDefaults.standard.bool(forKey: Self.publishingEnabledKey),
              UIApplication.shared.applicationState == .active,
              wallet.walletExists == true,
              wallet.nodeLifecycleState == .running,
              let ownPublicKey = await PubkyService.currentPublicKey()
        else {
            return false
        }

        return PubkyProfileManager.hasLocalSecretKey(for: ownPublicKey)
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

    func attemptedOutboundBolt11PaymentHashes() async -> Set<String> {
        guard let payments = await LightningService.shared.listPayments() else { return [] }

        return Set(
            payments.compactMap { payment in
                guard payment.direction == .outbound,
                      payment.status != .failed,
                      case .bolt11 = payment.kind
                else { return nil }

                return payment.id
            }
        )
    }
}
