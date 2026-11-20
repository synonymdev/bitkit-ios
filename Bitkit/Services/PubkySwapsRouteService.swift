import BitkitCore
import Foundation

/// A Paykit payment routed through a Pubky Swaps provider: the endpoint, the route once quoted, and its provider.
struct PaykitSwapRoute: Equatable {
    let endpoint: PaykitEndpoint
    var quote: PubkySwapRouteQuote?
    var providerName: String?
}

/// How a swap's claim wait ended without a claim: bitkit-core failed the swap, its hold payment failed so the provider
/// never funds it, or the wait ran out with the outcome still open, when the provider may yet settle the hold invoice.
enum PubkySwapClaimError: Error {
    case failed(String)
    case holdFailed
    case timedOut(Error)
}

/// Routes a Paykit payment through a Pubky Swaps provider when no balance the wallet holds reaches an endpoint the
/// contact published. bitkit-core picks the provider and checks its quote, contract and hold invoice; the wallet pays
/// the hold invoice from spending and bitkit-core claims the provider's lockup straight to the contact's address.
enum PubkySwapsRouteService {
    private static let claimFeeRateSatVb: UInt64 = 2
    private static let claimTimeout: TimeInterval = 10 * 60
    /// Within the 30 seconds iOS gives a background push, leaving time to acknowledge the wake.
    private static let claimableWakeTimeout: Duration = .seconds(18)
    private static let claimableWakePollInterval: Duration = .seconds(3)

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
        return await PubkySwapsTracker.shared.adoptRestored(restored: report.restored, known: report.known)
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

    /// Commits the quote and keeps its swap until its claim confirms or it fails, so a later start resumes it.
    static func commit(quoteId: String) async throws -> PubkySwapRoutePayment {
        let (mnemonic, passphrase) = try secrets()
        let payment = try await pubkySwapsCommitRoute(
            quoteId: quoteId,
            electrumUrl: Env.electrumServerUrl,
            mnemonic: mnemonic,
            bip39Passphrase: passphrase
        )
        await PubkySwapsTracker.shared.didCommit(payment.swapId)
        // Never holds up or fails the send: without a wake, the wallet claims when it next runs.
        Task.detached {
            await PubkySwapsWakeGrants.shared.handOver(swapId: payment.swapId, providerTakesWake: payment.providerTakesWake)
        }
        return payment
    }

    /// Records the hold payment of a committed swap, so its failure stops the swap, also after a restart.
    static func watchHold(swapId: String, paymentHash: String, invoice: String) async {
        await PubkySwapsTracker.shared.watchHold(PubkySwapHoldPayment(paymentHash: paymentHash, invoice: invoice), swapId: swapId)
    }

    /// Stops a swap whose hold payment failed or never went out: the provider never funds it.
    static func dropFailedSwap(swapId: String) async {
        Logger.info("Stopping Pubky Swaps route \(swapId) after its hold payment failed", context: "PubkySwapsRoute")
        await PubkySwapsTracker.shared.drop(swapId)
    }

    /// Advances each swap a closed app left unfinished until its claim confirms or it fails: the provider settles the
    /// hold invoice once it sees the claim, so a claim that never confirms could leave the contact unpaid.
    static func resumeUnfinishedSwaps() async {
        await PubkySwapsTracker.shared.resume()
    }

    static func resetForWipe() async {
        await PubkySwapsTracker.shared.resetForWipe()
        await PubkySwapsWakeGrants.shared.resetForWipe()
    }

    /// Claims the swaps a `swap.claimable` wake stands for, from the app delegate. Throws when no claim went out and a
    /// swap is still open, so the wake is acknowledged `failed`.
    static func handleClaimableWake() async throws {
        let isHandled = await PubkySwapsTracker.shared.advanceForClaimableWake(
            timeout: claimableWakeTimeout,
            interval: claimableWakePollInterval
        )
        guard isHandled else {
            throw AppError(message: "No swap claim went out for the wake", debugMessage: nil)
        }
    }

    /// Advance the swap until bitkit-core broadcasts the claim to the contact, returning the claim txid. The provider
    /// settles the hold invoice once it sees the claim, so the payment is done; the claim is still advanced in the
    /// background until it confirms, so bitkit-core rebroadcasts it if it drops out of the mempool.
    /// A wait that runs out keeps advancing the swap in the background too, so it can still claim and settle the hold
    /// payment, and throws `PubkySwapClaimError.timedOut`.
    static func awaitClaim(swapId: String) async throws -> String {
        try await PubkySwapsTracker.shared.awaitClaim(swapId: swapId, timeout: claimTimeout)
    }

    static func advance(swapId: String) async throws -> PubkySwapRouteState {
        let (mnemonic, passphrase) = try secrets()
        return try await pubkySwapsAdvance(swapId: swapId, mnemonic: mnemonic, bip39Passphrase: passphrase).state
    }

    static func isUnknownSwap(_ error: Error) -> Bool {
        guard case .NotFound? = error as? PubkySwapError else { return false }
        return true
    }

    /// Whether the hold payment failed. It goes out over the node or the channel-free rail, which shares its hash, and
    /// the rail decides a send the node failed. While the rail can't be asked, it counts as not failed.
    static func isHoldPaymentFailed(_ hold: PubkySwapHoldPayment) async -> Bool {
        let lightning = LightningService.shared
        let nodeStatus = await lightning.listPayments()?.first { payment in
            guard case let .bolt11(hash, _, _, _, _) = payment.kind else { return false }
            return hash.caseInsensitiveCompare(hold.paymentHash) == .orderedSame
        }?.status
        if let nodeStatus, nodeStatus != .failed {
            return false
        }
        guard let rail = lightning.channelFreeRail ?? lightning.channelFreePaymentHistory else {
            return await lightning.channelFreeRailSupported() ? false : nodeStatus == .failed
        }
        do {
            guard let railStatus = try await rail.lightningSendStatus(bolt11: hold.invoice) else { return nodeStatus == .failed }
            return railStatus == .failed
        } catch {
            return false
        }
    }

    static func secrets() throws -> (String, String?) {
        guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: 0)) else {
            throw AppError(message: "Mnemonic not found", debugMessage: nil)
        }
        return (mnemonic, try? Keychain.loadString(key: .bip39Passphrase(index: 0)))
    }
}
