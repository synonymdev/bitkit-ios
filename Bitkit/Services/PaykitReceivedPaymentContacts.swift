import BitkitCore
import Combine
import Foundation
import LDKNode
import os
import Paykit

struct PaykitReceivedPaymentContacts: Equatable {
    private var onchain: [String: Set<String>] = [:]
    private var paymentHashes: [String: Set<String>] = [:]

    init(records: [PaymentRequestRecord] = [], network: LDKNode.Network = Env.network) {
        for record in records {
            guard record.localRole == .payee,
                  record.state != .invalidConflict,
                  record.state != .unknown,
                  record.invalidReason == nil,
                  record.counterparty.trimmingCharacters(in: .whitespacesAndNewlines).count <= PubkyPublicKeyFormat.maximumInputLength,
                  let counterparty = PubkyPublicKeyFormat.normalized(record.counterparty),
                  let terms = record.terms, terms.amount.asset == PaykitIssuerInterop.bitcoinAsset,
                  let endpoints = terms.paymentEndpoints
            else { continue }

            for (identifier, data) in endpoints {
                guard terms.acceptedPaymentEndpointIdentifiers.contains(identifier),
                      let method = PublicPaykitService.MethodId(rawValue: identifier),
                      let payload = PaykitIssuerInterop.parseEndpointPayload(data)
                else { continue }

                if method.onchainNetwork == network {
                    guard let address = try? validateBitcoinAddress(address: payload.value) else { continue }
                    let addressNetwork = NetworkValidationHelper.convertNetworkType(address.network)
                    // Test networks share legacy address encodings; the endpoint identifies the intended network.
                    guard addressNetwork == network || (addressNetwork == .testnet && (network == .signet || network == .regtest)) else { continue }
                    onchain[payload.value, default: []].insert(counterparty)
                } else if method == .bitcoinLightningBolt11,
                          let invoice = try? Bolt11Invoice.fromStr(invoiceStr: payload.value),
                          invoice.currency() == Self.currency(for: network)
                {
                    paymentHashes[invoice.paymentHash().lowercased(), default: []].insert(counterparty)
                }
            }
        }
    }

    var isEmpty: Bool {
        onchain.isEmpty && paymentHashes.isEmpty
    }

    func contact(onchainAddresses: [String]) -> String? {
        let contacts = Set(onchainAddresses.flatMap { onchain[$0] ?? [] })
        return contacts.count == 1 ? contacts.first : nil
    }

    func contact(paymentHash: String) -> String? {
        let contacts = paymentHashes[paymentHash.lowercased()] ?? []
        return contacts.count == 1 ? contacts.first : nil
    }

    func includingReservations(
        for outputAddresses: [String],
        lookup: (String) async throws -> String?
    ) async rethrows -> Self {
        var combined = self
        for address in Set(outputAddresses) {
            guard let reservedContact = try await lookup(address),
                  let contact = PubkyPublicKeyFormat.normalized(reservedContact)
            else { continue }
            combined.onchain[address, default: []].insert(contact)
        }
        return combined
    }

    func contact(receivingAddress: String, outputAddresses: [String]) -> String? {
        guard !receivingAddress.isEmpty, outputAddresses.contains(receivingAddress),
              let contact = contact(onchainAddresses: [receivingAddress]),
              self.contact(onchainAddresses: outputAddresses) == contact
        else { return nil }
        return contact
    }

    func attributing(_ activity: Activity, outputAddresses: [String] = []) -> Activity? {
        switch activity {
        case var .onchain(payment):
            guard payment.txType == .received, payment.contact == nil,
                  let contact = contact(receivingAddress: payment.address, outputAddresses: outputAddresses)
            else { return nil }
            payment.contact = contact
            payment.updatedAt = UInt64(Date().timeIntervalSince1970)
            return .onchain(payment)
        case var .lightning(payment):
            guard payment.txType == .received, payment.contact == nil, payment.status == .succeeded,
                  let contact = contact(paymentHash: payment.id)
            else { return nil }
            payment.contact = contact
            payment.updatedAt = UInt64(Date().timeIntervalSince1970)
            return .lightning(payment)
        }
    }

    private static func currency(for network: LDKNode.Network) -> LDKNode.Currency {
        switch network {
        case .bitcoin: .bitcoin
        case .testnet: .bitcoinTestnet
        case .signet: .signet
        case .regtest: .regtest
        }
    }
}

final class PaykitReceivedPaymentBackfillCache {
    private struct Snapshot: Equatable {
        let identity: String
        let contacts: PaykitReceivedPaymentContacts
        let activityRevision: UInt64
        let reservationRevision: UInt64
    }

    private let state = OSAllocatedUnfairLock(initialState: (revision: UInt64(0), snapshot: Snapshot?.none))
    private var activityChanges: AnyCancellable?

    init(activityChanges: AnyPublisher<Void, Never>) {
        self.activityChanges = activityChanges.sink { [weak self] in self?.invalidate() }
    }

    func invalidate() {
        state.withLock {
            $0.revision &+= 1
            $0.snapshot = nil
        }
    }

    func scanIfNeeded(
        identity: String,
        contacts: PaykitReceivedPaymentContacts,
        reservationRevision: UInt64,
        scan: () async throws -> Bool
    ) async rethrows {
        let snapshot: Snapshot? = state.withLock {
            let snapshot = Snapshot(identity: identity, contacts: contacts, activityRevision: $0.revision, reservationRevision: reservationRevision)
            guard $0.snapshot != snapshot else { return nil }
            $0.snapshot = nil
            return snapshot
        }
        guard let snapshot, try await scan() else { return }
        state.withLock {
            guard $0.revision == snapshot.activityRevision else { return }
            $0.snapshot = snapshot
        }
    }
}

extension ActivityService {
    func backfillReceivedPaykitContacts(
        _ contacts: PaykitReceivedPaymentContacts,
        identity: String,
        cache: PaykitReceivedPaymentBackfillCache,
        reservations: PrivatePaykitAddressReservationStore = .shared,
        isCurrent: @Sendable () async -> Bool
    ) async throws {
        let reservationRevision = await reservations.attributionRevision
        try await cache.scanIfNeeded(identity: identity, contacts: contacts, reservationRevision: reservationRevision) {
            let activities = try await ServiceQueue.background(.core) {
                try getActivities(
                    walletId: WalletScope.default, filter: .all, txType: .received,
                    tags: nil, search: nil, minDate: nil, maxDate: nil, limit: nil, sortDirection: nil
                )
            }
            var changed = false
            var complete = true
            defer { if changed { notifyActivitiesChanged() } }
            for activity in activities {
                guard !Task.isCancelled, await isCurrent() else { return false }
                guard !isContactDetached(activityId: ActivityScope.id(of: activity), walletId: ActivityScope.walletId(of: activity)) else { continue }
                var outputAddresses: [String] = []
                var combined = contacts
                switch activity {
                case let .onchain(payment):
                    guard payment.contact == nil else { continue }
                    guard let details = try await getTransactionDetails(txid: payment.txId, walletId: payment.walletId) else {
                        complete = false
                        continue
                    }
                    outputAddresses = details.outputs.compactMap(\.scriptpubkeyAddress)
                    guard !outputAddresses.isEmpty else {
                        complete = false
                        continue
                    }
                    combined = try await contacts.includingReservations(for: outputAddresses) {
                        try await reservations.contactPublicKeyForAttribution(forReservedAddress: $0)
                    }
                case let .lightning(payment):
                    guard payment.contact == nil else { continue }
                }
                guard let updated = combined.attributing(activity, outputAddresses: outputAddresses) else { continue }
                guard !Task.isCancelled, await isCurrent(), await reservations.attributionRevision == reservationRevision else { return false }
                let didUpdate = try await ServiceQueue.background(.core) {
                    // Async lookups must not overwrite a contact or metadata written in the meantime.
                    guard !self.isContactDetached(activityId: activity.activityId, walletId: WalletScope.default),
                          try getActivityById(walletId: WalletScope.default, activityId: activity.activityId) == activity
                    else { return false }
                    try updateActivity(activityId: activity.activityId, activity: updated)
                    return true
                }
                changed = changed || didUpdate
                complete = complete && didUpdate
            }
            guard complete, !Task.isCancelled, await isCurrent(), await reservations.attributionRevision == reservationRevision else { return false }
            return true
        }
    }
}
