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
    /// How often a broadcast claim is advanced, so bitkit-core rebroadcasts it until it confirms.
    private static let confirmationPollInterval: Duration = .seconds(30)
    /// How long a broadcast claim is advanced in the background before polling stops.
    private static let confirmationTimeout: TimeInterval = 60 * 60

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
        let candidates = Self.candidates(contacts: contacts)
        Logger.debug("Routing Paykit payment via \(candidates.map(PubkyPublicKeyFormat.redacted))", context: "PubkySwapsRoute")
        let (mnemonic, passphrase) = try secrets()
        return try await pubkySwapsRoutePaykitPayment(
            request: PaykitRouteRequest(
                amountSat: amountSats,
                contactEndpoints: [endpoint],
                lightningSpendableSat: lightningSpendableSats,
                onchainSpendableSat: onchainSpendableSats,
                serviceLegs: serviceLegs,
                providers: candidates,
                feeRateSatVb: claimFeeRateSatVb
            ),
            network: Env.bitkitCoreNetwork,
            mnemonic: mnemonic,
            bip39Passphrase: passphrase
        )
    }

    /// Rebuilds the swaps this wallet started from each provider's listing, after a restore from the seed. The listing
    /// does not carry the contact's address, so a restored swap claims to a fresh Savings address. bitkit-core checks
    /// each listed lockup against the Lightning payment this node sent for its hash. Swaps already on record keep the
    /// destination they were committed with.
    static func restoreSwaps(contacts: [String]) async throws -> (restored: [String], known: [String]) {
        let (mnemonic, passphrase) = try secrets()
        let payoutAddress = try await LightningService.shared.newAddress()
        let payments = try await sentPayments()
        let report = try await pubkySwapsRestore(
            providers: candidates(contacts: contacts),
            sentPayments: payments,
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
        return (report.restored, report.known)
    }

    /// Providers come from the user's own graph: every contact is asked for its swap offer. bitkit-core caps the
    /// candidates, so configured providers go first and each key is asked once.
    static func candidates(contacts: [String], providers: [String] = Env.pubkySwapsProviders) -> [String] {
        var seen = Set<String>()
        return (providers + contacts).filter { seen.insert(PubkyPublicKeyFormat.normalized($0) ?? $0).inserted }
    }

    /// The Lightning payments this node sent, pending or settled, by hash and the amount paid to the payee.
    private static func sentPayments() async throws -> [PubkySwapSentPayment] {
        // Without the node's payments no listed swap can be checked, so restore nothing rather than nothing silently.
        guard let payments = await LightningService.shared.listPayments() else {
            throw AppError(message: "Lightning node not running", debugMessage: "listPayments returned nil")
        }
        return payments.compactMap { payment in
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

    /// Advance the swap until bitkit-core broadcasts the claim to the contact, returning the claim txid. The provider
    /// settles the hold invoice once it sees the claim, so the payment is done; the claim is still advanced in the
    /// background so bitkit-core rebroadcasts it until it confirms.
    static func awaitClaim(swapId: String) async throws -> String {
        let txid = try await pollClaim(swapId: swapId, interval: pollInterval, timeout: claimTimeout, untilConfirmed: false)
        Task.detached {
            do {
                let confirmed = try await pollClaim(
                    swapId: swapId, interval: confirmationPollInterval, timeout: confirmationTimeout, untilConfirmed: true
                )
                Logger.info("Confirmed Pubky Swaps claim \(confirmed) for \(swapId)", context: "PubkySwapsRoute")
            } catch {
                Logger.warn("Failed to confirm Pubky Swaps claim for \(swapId): \(error)", context: "PubkySwapsRoute")
            }
        }
        return txid
    }

    private static func pollClaim(
        swapId: String,
        interval: Duration,
        timeout: TimeInterval,
        untilConfirmed: Bool
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var lastFailure: Error = AppError(message: "Swap \(swapId) not claimed yet", debugMessage: nil)
        while true {
            try Task.checkCancellation()
            let (mnemonic, passphrase) = try secrets()
            let state: PubkySwapRouteState?
            do {
                state = try await pubkySwapsAdvance(swapId: swapId, mnemonic: mnemonic, bip39Passphrase: passphrase).state
            } catch {
                // A failed advance, such as a transient Electrum error, is retried: the swap is already funded.
                Logger.warn("Failed to advance Pubky Swaps route \(swapId): \(error)", context: "PubkySwapsRoute")
                lastFailure = error
                state = nil
            }
            switch state {
            case let .claimed(txid)?:
                return txid
            case let .claimBroadcast(txid)? where !untilConfirmed:
                return txid
            case let .failed(reason)?:
                throw AppError(message: reason, debugMessage: nil)
            case let state?:
                Logger.debug("Pubky Swaps route \(swapId): \(state)", context: "PubkySwapsRoute")
                lastFailure = AppError(message: "Swap \(swapId) not claimed yet", debugMessage: "\(state)")
            case nil:
                break
            }
            guard Date() < deadline else { throw lastFailure }
            try await Task.sleep(for: interval)
        }
    }

    private static func secrets() throws -> (String, String?) {
        guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: 0)) else {
            throw AppError(message: "Mnemonic not found", debugMessage: nil)
        }
        return (mnemonic, try? Keychain.loadString(key: .bip39Passphrase(index: 0)))
    }
}
