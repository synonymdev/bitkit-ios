import Foundation
import Paykit

// MARK: - Payment Resolution

extension PrivatePaykitService {
    func contactPublicKey(forPrivateInvoicePaymentHash paymentHash: String) -> String? {
        guard !paymentHash.isEmpty else { return nil }

        return state.contacts.first { _, contactState in
            contactState.localInvoice?.paymentHash == paymentHash ||
                contactState.receivedInvoicePaymentHashes.contains(paymentHash)
        }?.key
    }

    func resolveSavedContactPayableEndpoint(publicKey: String, wallet: WalletViewModel) async -> Bool {
        guard let normalizedKey = knownSavedContact(publicKey) else {
            return await (try? PublicPaykitService.hasPayablePublicEndpoint(publicKey: publicKey)) == true
        }

        do {
            let result = try await beginPrivateOrPublicPayment(to: normalizedKey, wallet: wallet)
            if case .opened = result {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    func resolvePayableEndpoint(publicKey: String, wallet: WalletViewModel) async -> Bool {
        await resolveSavedContactPayableEndpoint(publicKey: publicKey, wallet: wallet)
    }

    func beginSavedContactPayment(to publicKey: String, wallet: WalletViewModel) async throws -> PublicPaykitPaymentLaunchResult {
        guard let normalizedKey = knownSavedContact(publicKey) else {
            return try await PublicPaykitService.beginPayment(to: publicKey)
        }

        return try await beginPrivateOrPublicPayment(to: normalizedKey, wallet: wallet)
    }

    private func beginPrivateOrPublicPayment(to publicKey: String, wallet: WalletViewModel) async throws -> PublicPaykitPaymentLaunchResult {
        let isPrivateCapable = await hasLocalSecretKeyForCurrentProfile()

        if isPrivateCapable, await canPublishPrivateEndpoints(wallet: wallet) {
            _ = await refreshSavedContactEndpointsReturningError(
                for: [publicKey],
                wallet: wallet,
                forceRefreshLightning: false,
                requireImmediatePublication: false
            )
        }

        do {
            let prepared = try await PaykitSdkService.shared.prepareAndResolveContactPayment(counterparty: publicKey, includePublicEndpoints: true)
            let resolution = prepared.resolution
            let privateEndpoints = resolvedEndpoints(from: resolution, source: .privatePaymentList)
            cacheResolvedEndpoints(privateEndpoints, publicKey: publicKey)

            let payableEndpoints = await privatePayableEndpoints(from: privateEndpoints, publicKey: publicKey)

            if !payableEndpoints.isEmpty {
                return .opened(paymentRequest: PublicPaykitService.paymentRequest(from: payableEndpoints))
            }

            if resolution.privateState == .recoveryPending {
                schedulePrivatePaymentRecovery(for: publicKey)
                return .noEndpoint
            }

            let publicEndpoints = resolvedEndpoints(from: resolution, source: .publicPaymentEndpoint)
            let publicPayableEndpoints = await PublicPaykitService.payableEndpoints(from: publicEndpoints)
            if !publicPayableEndpoints.isEmpty {
                return .opened(paymentRequest: PublicPaykitService.paymentRequest(from: publicPayableEndpoints))
            }

            return (privateEndpoints.isEmpty && publicEndpoints.isEmpty) ? .noEndpoint : .notOpened
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw error
            }

            Logger.warn(
                "Failed to resolve Paykit contact payment for \(PubkyPublicKeyFormat.redacted(publicKey)): \(error)",
                context: "PrivatePaykit"
            )
            return try await PublicPaykitService.beginPayment(to: publicKey)
        }
    }

    private func hasLocalSecretKeyForCurrentProfile() async -> Bool {
        guard let status = try? await PaykitSdkService.shared.identityStatus() else { return false }
        return status.privateLinkCapable
    }

    func privatePayableEndpoints(from endpoints: [PublicPaykitService.Endpoint], publicKey: String) async -> [PublicPaykitService.Endpoint] {
        let payableEndpoints = await PublicPaykitService.payableEndpoints(from: endpoints)
        var reusableEndpoints: [PublicPaykitService.Endpoint] = []
        var staleLightningPaymentHashes = Set<String>()

        for endpoint in payableEndpoints {
            if endpoint.methodId == .bitcoinLightningBolt11 {
                guard let paymentHash = await paymentHash(forBolt11: endpoint.value) else {
                    continue
                }

                guard PublicPaykitService.hasLightningRouteHints(bolt11: endpoint.value),
                      await !hasAttemptedOutboundBolt11Payment(paymentHash: paymentHash)
                else {
                    staleLightningPaymentHashes.insert(paymentHash)
                    continue
                }

                reusableEndpoints.append(endpoint)
                continue
            }

            guard PublicPaykitService.MethodId.onchainPreferenceOrder.contains(endpoint.methodId) else {
                reusableEndpoints.append(endpoint)
                continue
            }

            do {
                let isUsed = try await CoreService.shared.utility.isAddressUsed(address: endpoint.value)
                if !isUsed {
                    reusableEndpoints.append(endpoint)
                }
            } catch {
                Logger.warn(
                    "Failed to verify private Paykit on-chain endpoint usage for \(PubkyPublicKeyFormat.redacted(publicKey)): \(error)",
                    context: "PrivatePaykit"
                )
            }
        }

        if !staleLightningPaymentHashes.isEmpty {
            await discardRemoteLightningEndpoints(publicKey: publicKey, paymentHashes: staleLightningPaymentHashes)
        }

        return reusableEndpoints
    }

    func discardRemoteLightningEndpoints(publicKey: String, paymentHashes: Set<String>) async {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey),
              var contactState = state.contacts[normalizedKey],
              !paymentHashes.isEmpty
        else { return }

        let previousCount = contactState.cachedResolvedEndpoints.count
        var filteredEntries: [StoredPaymentEntry] = []

        for entry in contactState.cachedResolvedEndpoints {
            guard entry.methodId == PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue,
                  let endpoint = PublicPaykitService.parseEndpoint(methodId: entry.methodId, endpointData: entry.endpointData),
                  let paymentHash = await paymentHash(forBolt11: endpoint.value),
                  paymentHashes.contains(paymentHash)
            else {
                filteredEntries.append(entry)
                continue
            }
        }

        guard filteredEntries.count != previousCount else { return }

        contactState.cachedResolvedEndpoints = filteredEntries
        state.contacts[normalizedKey] = contactState
        persistState(markWalletBackup: true)
    }

    func discardRemoteOnchainEndpoints(publicKey: String, addresses: Set<String>) async {
        guard let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey),
              var contactState = state.contacts[normalizedKey],
              !addresses.isEmpty
        else { return }

        let previousCount = contactState.cachedResolvedEndpoints.count
        contactState.cachedResolvedEndpoints = contactState.cachedResolvedEndpoints.filter { entry in
            guard PublicPaykitService.MethodId.onchainPreferenceOrder.contains(where: { $0.rawValue == entry.methodId }),
                  let endpoint = PublicPaykitService.parseEndpoint(methodId: entry.methodId, endpointData: entry.endpointData)
            else {
                return true
            }

            return !addresses.contains(endpoint.value)
        }

        guard contactState.cachedResolvedEndpoints.count != previousCount else { return }

        state.contacts[normalizedKey] = contactState
        persistState(markWalletBackup: true)
    }

    private func resolvedEndpoints(from resolution: ContactPaymentResolution, source: PaymentEndpointSource) -> [PublicPaykitService.Endpoint] {
        resolution.payableEndpoints.compactMap {
            guard $0.source == source else { return nil }

            return PublicPaykitService.parseEndpoint(identifier: $0.identifier, payload: $0.target.payload)
        }
    }
}
