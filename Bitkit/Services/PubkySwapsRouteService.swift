import BitkitCore
import Foundation

/// A Paykit payment routed through a Pubky Swaps provider: the endpoint, the route once quoted, and its provider.
struct PaykitSwapRoute: Equatable {
    let endpoint: PaykitEndpoint
    var quote: PubkySwapRouteQuote?
    var providerName: String?
}

/// Routes a Paykit payment through a Pubky Swaps provider when no balance the wallet holds reaches an endpoint the
/// contact published. bitkit-core picks the provider and checks its quote, contract and hold invoice; the wallet pays
/// the hold invoice from spending and bitkit-core claims the provider's lockup straight to the contact's address.
enum PubkySwapsRouteService {
    private static let claimFeeRateSatVb: UInt64 = 2
    private static let pollInterval: Duration = .seconds(2)
    private static let claimTimeout: TimeInterval = 10 * 60

    static var isEnabled: Bool {
        Env.isPubkySwapsRouteEnabled
    }

    /// A contact whose only endpoints are on-chain, paid when savings cannot cover it but spending can.
    static func route(for context: ContactPaymentContext, address: String, onchainBalanceSats: UInt64,
                      lightningBalanceSats: UInt64) -> PaykitSwapRoute?
    {
        guard isEnabled, context.incomingPaymentRequest == nil, !address.isEmpty,
              !context.endpoints.isEmpty, context.endpoints.allSatisfy({ $0.methodId.onchainNetwork != nil }),
              onchainBalanceSats <= UInt64(Env.dustLimit), lightningBalanceSats > 0,
              let methodId = context.endpoints.first?.methodId
        else { return nil }
        return PaykitSwapRoute(endpoint: PaykitEndpoint(methodId: methodId.rawValue, value: address))
    }

    static func quote(
        amountSats: UInt64,
        endpoint: PaykitEndpoint,
        lightningSpendableSats: UInt64,
        onchainSpendableSats: UInt64,
        contacts: [String],
        serviceLegs: [ServiceRouteLeg] = []
    ) async throws -> PaykitRoute {
        // Providers come from the user's own graph: every contact is asked for its swap offer.
        let candidates = contacts + Env.pubkySwapsProviders
        Logger.debug("Routing Paykit payment via \(candidates.map(PubkyPublicKeyFormat.redacted))", context: "PubkySwapsRoute")
        let (mnemonic, passphrase) = try secrets()
        return try await pubkySwapsRoutePaykitPayment(
            request: PaykitRouteRequest(
                amountSat: amountSats,
                contactEndpoints: [endpoint],
                lightningSpendableSat: lightningSpendableSats,
                onchainSpendableSat: onchainSpendableSats,
                providers: candidates,
                feeRateSatVb: claimFeeRateSatVb,
                serviceLegs: serviceLegs
            ),
            network: Env.bitkitCoreNetwork,
            mnemonic: mnemonic,
            bip39Passphrase: passphrase
        )
    }

    /// Rebuilds the swaps this wallet started from each provider's listing, after a restore from the seed. The listing
    /// does not carry the contact's address, so a restored swap claims to a fresh Savings address. bitkit-core checks
    /// each listed lockup against the Lightning payment this node sent for its hash. Returns the ids to drive: the swaps
    /// restored now and those already on record.
    static func restoreSwaps(contacts: [String]) async throws -> [String] {
        let (mnemonic, passphrase) = try secrets()
        let payoutAddress = try await LightningService.shared.newAddress()
        let report = try await pubkySwapsRestore(
            providers: contacts + Env.pubkySwapsProviders,
            sentPayments: await sentPayments(),
            electrumUrl: Env.electrumServerUrl,
            payoutAddress: payoutAddress,
            feeRateSatVb: claimFeeRateSatVb,
            network: Env.bitkitCoreNetwork,
            mnemonic: mnemonic,
            bip39Passphrase: passphrase
        )
        if !report.incompleteProviders.isEmpty {
            Logger.warn("Swap lists incomplete from \(report.incompleteProviders)", context: "PubkySwapsRoute")
        }
        return report.restored + report.known
    }

    /// The Lightning payments this node sent, pending or settled, by hash and the amount paid to the payee.
    private static func sentPayments() async -> [PubkySwapSentPayment] {
        (await LightningService.shared.listPayments() ?? []).compactMap { payment in
            guard payment.direction == .outbound, payment.status != .failed,
                  case let .bolt11(hash, _, _, _, _) = payment.kind,
                  let amountMsat = payment.amountMsat
            else { return nil }
            return PubkySwapSentPayment(
                paymentHashHex: hash,
                amountSat: amountMsat / 1000,
                settled: payment.status == .succeeded
            )
        }
    }

    static func commit(quoteId: String) async throws -> PubkySwapRoutePayment {
        let (mnemonic, passphrase) = try secrets()
        return try await pubkySwapsCommitRoute(
            quoteId: quoteId,
            electrumUrl: Env.electrumServerUrl,
            mnemonic: mnemonic,
            bip39Passphrase: passphrase
        )
    }

    /// Advance the swap until bitkit-core claims the lockup to the contact, returning the claim txid.
    static func awaitClaim(swapId: String) async throws -> String {
        let deadline = Date().addingTimeInterval(claimTimeout)
        while true {
            let (mnemonic, passphrase) = try secrets()
            let status = try await pubkySwapsAdvance(swapId: swapId, mnemonic: mnemonic, bip39Passphrase: passphrase)
            switch status.state {
            case let .claimed(txid):
                return txid
            case let .failed(reason):
                throw AppError(message: reason, debugMessage: nil)
            default:
                Logger.debug("Pubky Swaps route \(swapId): \(status.state)", context: "PubkySwapsRoute")
            }
            guard Date() < deadline else {
                throw AppError(message: "Swap \(swapId) not claimed yet", debugMessage: "\(status.state)")
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    private static func secrets() throws -> (String, String?) {
        guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: 0)) else {
            throw AppError(message: "Mnemonic not found", debugMessage: nil)
        }
        return (mnemonic, try? Keychain.loadString(key: .bip39Passphrase(index: 0)))
    }
}
