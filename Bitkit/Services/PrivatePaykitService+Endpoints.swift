import CryptoKit
import Foundation
import Paykit

// MARK: - Endpoint Preparation

extension PrivatePaykitService {
    func handleReceivedPayment(paymentHash: String, wallet: WalletViewModel) async {
        guard let publicKey = contactPublicKey(forPrivateInvoicePaymentHash: paymentHash) else { return }
        rememberReceivedInvoicePaymentHash(paymentHash, publicKey: publicKey)
        await refreshSavedContactEndpoints(for: [publicKey], wallet: wallet)
    }

    func reconcileReceivedPayments(wallet: WalletViewModel) async {
        let settledHashes = await settledPrivateInvoicePaymentHashes()
        guard !settledHashes.isEmpty else { return }

        for paymentHash in settledHashes {
            await handleReceivedPayment(paymentHash: paymentHash, wallet: wallet)
        }
    }

    func handleOnchainActivity(wallet: WalletViewModel) async {
        let publicKeys = await PrivatePaykitAddressReservationStore.shared.contactsWithUsedReservedAddresses()
            .compactMap(knownSavedContact)
        guard !publicKeys.isEmpty else { return }

        await refreshSavedContactEndpoints(for: publicKeys, wallet: wallet, forceRefreshLightning: false)
    }

    func handleOnchainActivity(receivedAddresses: [String], wallet: WalletViewModel) async {
        var publicKeys: [String] = []
        for address in receivedAddresses {
            if let publicKey = await PrivatePaykitAddressReservationStore.shared.currentContactPublicKey(forReservedAddress: address),
               let savedKey = knownSavedContact(publicKey)
            {
                publicKeys.append(savedKey)
            }
        }

        guard !publicKeys.isEmpty else { return }
        await refreshSavedContactEndpoints(for: publicKeys, wallet: wallet, forceRefreshLightning: false)
    }

    @MainActor
    func buildLocalEndpoints(
        for publicKey: String,
        wallet: WalletViewModel,
        forceRefreshLightning: Bool = false
    ) async throws -> [PublicPaykitService.Endpoint] {
        var endpoints: [PublicPaykitService.Endpoint] = []

        if PublicPaykitService.isOnchainPaymentOptionEnabled() {
            let reservedAddress = try await PrivatePaykitAddressReservationStore.shared.currentOrRotatedAddress(for: publicKey)
            let onchainPayload = try PublicPaykitService.serializePayload(value: reservedAddress)
            endpoints.append(
                PublicPaykitService.Endpoint(
                    methodId: PublicPaykitService.onchainMethodId(for: reservedAddress),
                    value: reservedAddress,
                    min: nil,
                    max: nil,
                    rawPayload: onchainPayload
                )
            )
        }

        if PublicPaykitService.isLightningPaymentOptionEnabled(), walletHasUsableChannels(wallet) {
            do {
                let invoice = try await currentOrRotatedInvoice(for: publicKey, wallet: wallet, forceRefresh: forceRefreshLightning)
                let invoicePayload = try PublicPaykitService.serializePayload(value: invoice.bolt11)
                endpoints.append(
                    PublicPaykitService.Endpoint(
                        methodId: .bitcoinLightningBolt11,
                        value: invoice.bolt11,
                        min: nil,
                        max: nil,
                        rawPayload: invoicePayload
                    )
                )
            } catch PrivatePaykitError.routeHintsUnavailable {
                Logger.warn("Private Paykit Lightning invoice has no route hints; publishing on-chain endpoint only", context: "PrivatePaykit")
            }
        }

        guard !endpoints.isEmpty else {
            throw PublicPaykitError.noSupportedEndpoint
        }

        return endpoints
    }

    func reservations(from endpoints: [PublicPaykitService.Endpoint], publicKey: String) -> [PaymentEndpointReservationInput] {
        endpoints.map { endpoint in
            let paymentHash = state.contacts[publicKey]?.localInvoice?.takeIfBolt11(endpoint)?.paymentHash
            let attribution = [
                "type": "private_paykit",
                "counterparty": publicKey,
            ].merging(paymentHash.map { ["payment_hash": $0] } ?? [:]) { current, _ in current }

            return PaymentEndpointReservationInput(
                reservationId: reservationId(for: endpoint, publicKey: publicKey),
                identifier: endpoint.methodId.rawValue,
                payload: endpoint.rawPayload,
                expiresAt: endpoint.methodId == .bitcoinLightningBolt11 ? state.contacts[publicKey]?.localInvoice?.expiresAt.rfc3339Text : nil,
                attribution: attribution
            )
        }
    }

    private func reservationId(for endpoint: PublicPaykitService.Endpoint, publicKey: String) -> String {
        let payloadHashPrefix = SHA256.hash(data: Data(endpoint.rawPayload.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(publicKey):\(endpoint.methodId.rawValue):\(payloadHashPrefix)"
    }

    func cacheResolvedEndpoints(_ endpoints: [PublicPaykitService.Endpoint], publicKey: String) {
        var contactState = state.contacts[publicKey, default: ContactState()]
        contactState.cachedResolvedEndpoints = endpoints.map(StoredPaymentEntry.init(endpoint:))
        state.contacts[publicKey] = contactState
        persistState(markWalletBackup: true)
    }
}

private extension PrivatePaykitService.StoredInvoice {
    func takeIfBolt11(_ endpoint: PublicPaykitService.Endpoint) -> Self? {
        endpoint.methodId == .bitcoinLightningBolt11 && bolt11 == endpoint.value ? self : nil
    }
}

private extension Double {
    var rfc3339Text: String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: self))
    }
}
