import CryptoKit
import Foundation
import Paykit

// MARK: - Endpoint Publishing

extension PrivatePaykitService {
    static func isNoisePayloadWithinLimit(_ paymentMap: [String: String]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: paymentMap) else {
            return false
        }
        return data.count <= maxNoisePayloadBytes
    }

    func handleReceivedPayment(paymentHash: String, wallet: WalletViewModel) async {
        let matchingContacts = state.contacts.compactMap { publicKey, contactState -> String? in
            guard isKnownSavedContact(publicKey) else { return nil }
            return contactState.localInvoice?.paymentHash == paymentHash ? publicKey : nil
        }

        guard !matchingContacts.isEmpty else { return }

        for publicKey in matchingContacts {
            rememberReceivedInvoicePaymentHash(paymentHash, publicKey: publicKey)
        }

        guard await canPublishPrivateEndpoints(wallet: wallet) else { return }

        for publicKey in matchingContacts {
            let generation = stateGeneration
            do {
                guard let linkId = try await establishedLinkId(for: publicKey, maxAdvanceSteps: 1, generation: generation) else {
                    continue
                }
                try await publishLocalEndpoints(to: publicKey, linkId: linkId, wallet: wallet, generation: generation)
            } catch {
                Logger.warn(
                    "Failed to rotate private Paykit invoice for \(PubkyPublicKeyFormat.redacted(publicKey)): \(error)",
                    context: "PrivatePaykit"
                )
            }
        }
    }

    func reconcileReceivedPayments(wallet: WalletViewModel) async {
        for paymentHash in await settledPrivateInvoicePaymentHashes() {
            await handleReceivedPayment(paymentHash: paymentHash, wallet: wallet)
        }
    }

    func handleOnchainActivity(wallet: WalletViewModel) async {
        guard await canPublishPrivateEndpoints(wallet: wallet) else { return }
        let publicKeys = await PrivatePaykitAddressReservationStore.shared.contactsWithUsedReservedAddresses()
            .filter(isKnownSavedContact)
        guard !publicKeys.isEmpty else { return }

        await rotateOnchainEndpoints(for: publicKeys, wallet: wallet, reason: "on-chain rotation", forceRotate: false)
    }

    func handleOnchainActivity(receivedAddresses: [String], wallet: WalletViewModel) async {
        let receivedAddresses = receivedAddresses.filter { !$0.isEmpty }
        guard !receivedAddresses.isEmpty else {
            await handleOnchainActivity(wallet: wallet)
            return
        }
        guard await canPublishPrivateEndpoints(wallet: wallet) else { return }

        var publicKeys = Set<String>()
        for address in receivedAddresses {
            if let publicKey = await PrivatePaykitAddressReservationStore.shared.currentContactPublicKey(forReservedAddress: address),
               isKnownSavedContact(publicKey)
            {
                publicKeys.insert(publicKey)
            }
        }
        guard !publicKeys.isEmpty else { return }

        await rotateOnchainEndpoints(for: Array(publicKeys), wallet: wallet, reason: "on-chain transaction output rotation", forceRotate: true)
    }

    private func rotateOnchainEndpoints(for publicKeys: [String], wallet: WalletViewModel, reason: String, forceRotate: Bool) async {
        var rotatedPublicKeys: [String] = []
        for publicKey in publicKeys {
            do {
                if forceRotate {
                    _ = try await PrivatePaykitAddressReservationStore.shared.rotateAddress(for: publicKey)
                } else {
                    _ = try await PrivatePaykitAddressReservationStore.shared.currentOrRotatedAddress(for: publicKey)
                }
                rotatedPublicKeys.append(publicKey)
            } catch {
                Logger.warn(
                    "Failed to rotate used private Paykit address for \(PubkyPublicKeyFormat.redacted(publicKey)): \(error)",
                    context: "PrivatePaykit"
                )
            }
        }

        guard !rotatedPublicKeys.isEmpty else { return }
        await publishLocalEndpoints(for: rotatedPublicKeys, wallet: wallet, maxAdvanceSteps: 1, reason: reason)
    }

    func publishLocalEndpointsBestEffort(to publicKey: String, linkId: String, wallet: WalletViewModel,
                                         generation: UInt64, context: String, fetchedRemoteCount: Int) async throws
    {
        guard await canPublishPrivateEndpoints(wallet: wallet) else { return }
        guard await shouldPublishLocalEndpoints(publicKey: publicKey, fetchedRemoteCount: fetchedRemoteCount) else { return }
        guard !shouldDeferInitialLocalPublish(publicKey: publicKey, fetchedRemoteCount: fetchedRemoteCount) else { return }

        do {
            try await publishLocalEndpoints(to: publicKey, linkId: linkId, wallet: wallet, generation: generation)
        } catch {
            try Task.checkCancellation()
            Logger.warn(
                "Failed to publish local private Paykit endpoints during \(context) for \(PubkyPublicKeyFormat.redacted(publicKey)); continuing with remote fetch: \(error)",
                context: "PrivatePaykit"
            )
        }
    }

    func shouldPublishLocalEndpoints(publicKey: String, fetchedRemoteCount: Int) async -> Bool {
        let contactState = state.contacts[publicKey]
        if contactState?.lastLocalPayloadHash != nil {
            return true
        }

        if fetchedRemoteCount > 0 || contactState?.remoteEndpoints.isEmpty == false {
            return true
        }

        guard let ownPublicKey = await PubkyService.currentPublicKey() else {
            return false
        }

        return Self.shouldInitiate(ownPublicKey: ownPublicKey, remotePublicKey: publicKey)
    }

    func shouldDeferInitialLocalPublish(publicKey: String, fetchedRemoteCount: Int) -> Bool {
        guard fetchedRemoteCount == 0,
              let contactState = state.contacts[publicKey],
              contactState.lastLocalPayloadHash == nil,
              contactState.remoteEndpoints.isEmpty,
              let linkCompletedAt = contactState.linkCompletedAt
        else {
            return false
        }

        let now = UInt64(Date().timeIntervalSince1970)
        return now <= linkCompletedAt + Self.freshLinkInitialPublishDelaySeconds
    }

    func publishLocalEndpoints(to publicKey: String, linkId: String, wallet: WalletViewModel, generation: UInt64, force: Bool = false) async throws {
        let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) ?? publicKey
        let previousTask = publicationTasks[normalizedKey]?.task
        let taskId = UUID()
        let task = Task { [weak self] in
            if let previousTask {
                try? await previousTask.value
            }
            guard let self else { throw PrivatePaykitError.privateUnavailable }
            try Task.checkCancellation()
            try await publishLocalEndpointsUnlocked(to: normalizedKey, linkId: linkId, wallet: wallet, generation: generation, force: force)
        }
        publicationTasks[normalizedKey] = PublicationTask(id: taskId, task: task)

        do {
            try await task.value
            if publicationTasks[normalizedKey]?.id == taskId {
                publicationTasks[normalizedKey] = nil
            }
        } catch {
            if publicationTasks[normalizedKey]?.id == taskId {
                publicationTasks[normalizedKey] = nil
            }
            throw error
        }
    }

    func publishLocalEndpointsUnlocked(to publicKey: String, linkId: String, wallet: WalletViewModel, generation: UInt64, force: Bool) async throws {
        guard await canPublishPrivateEndpoints(wallet: wallet),
              isKnownSavedContact(publicKey)
        else { return }
        try ensureCurrentGeneration(generation)
        let endpoints = try await buildLocalEndpoints(for: publicKey, wallet: wallet, generation: generation)
        try ensureCurrentGeneration(generation)
        guard !endpoints.isEmpty else { return }

        let entries = try entriesWithinNoiseLimit(from: endpoints, publicKey: publicKey)
        let payloadHash = localPayloadHash(entries: entries)
        guard force || state.contacts[publicKey]?.lastLocalPayloadHash != payloadHash else {
            return
        }

        try ensureCurrentGeneration(generation)
        guard await canPublishPrivateEndpoints(wallet: wallet),
              isKnownSavedContact(publicKey)
        else { return }

        do {
            try await PubkyService.setPrivatePayments(linkId: linkId, entries: entries)
            try ensureCurrentGeneration(generation)
        } catch {
            await recordLinkFailure(publicKey: publicKey, error: error, generation: generation)
            throw error
        }

        try await persistLinkSnapshot(linkId: linkId, publicKey: publicKey, generation: generation)
        state.contacts[publicKey, default: ContactState()].lastLocalPayloadHash = payloadHash
        persistState()
    }

    func buildLocalEndpoints(for publicKey: String, wallet: WalletViewModel,
                             generation: UInt64) async throws -> [PublicPaykitService.Endpoint]
    {
        var endpoints: [PublicPaykitService.Endpoint] = []
        let reservedAddress = try await PrivatePaykitAddressReservationStore.shared.currentOrRotatedAddress(for: publicKey)
        try ensureCurrentGeneration(generation)
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

        if await walletHasUsableChannels(wallet) {
            do {
                let invoice = try await currentOrRotatedInvoice(for: publicKey, wallet: wallet, generation: generation)
                try ensureCurrentGeneration(generation)
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
            } catch {
                try ensureCurrentGeneration(generation)
                state.contacts[publicKey]?.localInvoice = nil
                persistState()
                Logger.warn(
                    "Failed to prepare private Paykit Lightning invoice for \(PubkyPublicKeyFormat.redacted(publicKey)); publishing on-chain only: \(error)",
                    context: "PrivatePaykit"
                )
            }
        } else {
            try ensureCurrentGeneration(generation)
            state.contacts[publicKey]?.localInvoice = nil
            persistState()
        }

        return endpoints
    }

    func validateNoisePayload(entries: [FfiPaymentEntry]) throws {
        let map = Dictionary(uniqueKeysWithValues: entries.map { ($0.methodId, $0.endpointData) })
        guard Self.isNoisePayloadWithinLimit(map) else {
            throw PrivatePaykitError.payloadTooLarge
        }
    }

    func entriesWithinNoiseLimit(from endpoints: [PublicPaykitService.Endpoint], publicKey: String) throws -> [FfiPaymentEntry] {
        let entries = endpoints.map {
            FfiPaymentEntry(methodId: $0.methodId.rawValue, endpointData: $0.rawPayload)
        }

        do {
            try validateNoisePayload(entries: entries)
            return entries
        } catch let error as PrivatePaykitError {
            guard case .payloadTooLarge = error else {
                throw error
            }

            let onchainOnlyEntries = entries.filter { $0.methodId != PublicPaykitService.MethodId.bitcoinLightningBolt11.rawValue }
            guard onchainOnlyEntries.count < entries.count, !onchainOnlyEntries.isEmpty else {
                throw error
            }

            try validateNoisePayload(entries: onchainOnlyEntries)
            state.contacts[publicKey]?.localInvoice = nil
            persistState()
            Logger.warn(
                "Private Paykit endpoint map is too large with Lightning invoice for \(PubkyPublicKeyFormat.redacted(publicKey)); publishing on-chain only.",
                context: "PrivatePaykit"
            )
            return onchainOnlyEntries
        }
    }

    func privateEndpointRemovalEntries() -> [FfiPaymentEntry] {
        PublicPaykitService.MethodId.publishableMethodIds.map {
            FfiPaymentEntry(methodId: $0.rawValue, endpointData: Self.privateEndpointRemovalPayload)
        }
    }

    func localPayloadHash(entries: [FfiPaymentEntry]) -> String {
        let payload = entries
            .sorted { $0.methodId < $1.methodId }
            .map { entry in
                "\(entry.methodId.count):\(entry.methodId)\(entry.endpointData.count):\(entry.endpointData)"
            }
            .joined()

        return SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
