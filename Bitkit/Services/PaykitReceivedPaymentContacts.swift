import BitkitCore
import Foundation
import LDKNode
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

    func attributing(_ activity: Activity, outputAddresses: [String] = []) -> Activity? {
        switch activity {
        case var .onchain(payment):
            guard payment.txType == .received, payment.contact == nil,
                  outputAddresses.contains(payment.address),
                  let contact = contact(onchainAddresses: [payment.address]),
                  self.contact(onchainAddresses: outputAddresses) == contact
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

extension ActivityService {
    func backfillReceivedPaykitContacts(_ contacts: PaykitReceivedPaymentContacts) async throws {
        guard !contacts.isEmpty else { return }
        try await ServiceQueue.background(.core) {
            let activities = try getActivities(
                walletId: WalletScope.default, filter: .all, txType: .received,
                tags: nil, search: nil, minDate: nil, maxDate: nil, limit: nil, sortDirection: nil
            )
            var changed = false
            defer { if changed { self.notifyActivitiesChanged() } }
            for activity in activities {
                var outputAddresses: [String] = []
                if case let .onchain(payment) = activity {
                    guard payment.contact == nil else { continue }
                    guard let details = try BitkitCore.getTransactionDetails(walletId: payment.walletId, txId: payment.txId) else { continue }
                    outputAddresses = details.outputs.compactMap(\.scriptpubkeyAddress)
                }
                guard let updated = contacts.attributing(activity, outputAddresses: outputAddresses) else { continue }
                try updateActivity(activityId: activity.activityId, activity: updated)
                changed = true
            }
        }
    }
}
