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
        contacts: [String]
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
                feeRateSatVb: claimFeeRateSatVb
            ),
            network: Env.bitkitCoreNetwork,
            mnemonic: mnemonic,
            bip39Passphrase: passphrase
        )
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
