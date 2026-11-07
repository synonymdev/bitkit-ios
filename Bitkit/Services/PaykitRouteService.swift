import BitkitCore
import Foundation

/// A contact payment bitkit-core's Paykit router picks the way for: the contact's bitcoin endpoints, whether a Spark leg
/// may reach its on-chain ones, and the leg once the router picked one.
struct PaykitRouteUi: Equatable {
    let endpoints: [PaykitEndpoint]
    let offersSparkLeg: Bool
    var serviceLeg: ServiceRouteLeg?

    var deliveredSat: UInt64? {
        serviceLeg?.deliveredSat
    }

    var totalFeeSat: UInt64? {
        serviceLeg.map { $0.debitSat.saturatingSub($0.deliveredSat) }
    }

    var onchainEndpoints: [PaykitEndpoint] {
        endpoints.filter(\.isOnchain)
    }
}

extension PaykitEndpoint {
    var isOnchain: Bool {
        PublicPaykitService.MethodId(rawValue: methodId)?.onchainNetwork != nil
    }

    var isLnurl: Bool {
        methodId == PublicPaykitService.MethodId.bitcoinLightningLnurl.rawValue
    }
}

/// Routes every bitcoin contact payment through bitkit-core's Paykit router: Direct pays one of the contact's
/// endpoints, Service pays through a service the wallet holds a balance on (a Spark withdrawal to the contact's on-chain
/// address), None pays nothing.
enum PaykitRouteService {
    /// The source the payment is paid from, as picked on the amount screen.
    enum Source {
        case spending
        case savings
    }

    /// Spark can carry a leg while it is ready and holds a sendable balance.
    @MainActor
    static var canRouteThroughSpark: Bool {
        SparkManager.shared.isReady && SparkManager.shared.sendableSats > 0
    }

    /// The route for a contact payment, or nil without bitcoin endpoints. A Spark leg is offered to a contact with an
    /// on-chain endpoint while Spark can route and the payment can't go directly over Lightning; a request it pays gets
    /// its on-chain proof from the withdrawal's txid.
    static func routeUi(
        for context: ContactPaymentContext,
        canRouteThroughSpark: Bool,
        canPayDirectly: Bool
    ) -> PaykitRouteUi? {
        let endpoints = context.endpoints
            .filter { $0.methodId != .usdtArbitrum }
            .map { PaykitEndpoint(methodId: $0.methodId.rawValue, value: $0.value) }
        guard !endpoints.isEmpty else { return nil }
        let offersSparkLeg = canRouteThroughSpark && !canPayDirectly && endpoints.contains(where: \.isOnchain)
        return PaykitRouteUi(endpoints: endpoints, offersSparkLeg: offersSparkLeg)
    }

    /// What the router is asked from `source`: Spending offers every endpoint, Savings only the on-chain ones.
    static func request(
        route: PaykitRouteUi,
        amountSats: UInt64,
        source: Source,
        lightningSpendableSats: UInt64,
        onchainSpendableSats: UInt64,
        serviceLegs: [ServiceRouteLeg]
    ) -> PaykitRouteRequest {
        switch source {
        case .spending:
            PaykitRouteRequest(
                amountSat: amountSats,
                contactEndpoints: route.endpoints,
                lightningSpendableSat: lightningSpendableSats,
                onchainSpendableSat: 0,
                serviceLegs: serviceLegs
            )
        case .savings:
            PaykitRouteRequest(
                amountSat: amountSats,
                contactEndpoints: route.onchainEndpoints,
                lightningSpendableSat: 0,
                onchainSpendableSat: onchainSpendableSats,
                serviceLegs: []
            )
        }
    }

    /// Asks the router how to pay `amountSats` from `source`, quoting a Spark leg to each on-chain endpoint first when
    /// the route offers one.
    static func route(
        _ route: PaykitRouteUi,
        amountSats: UInt64,
        source: Source,
        lightningSpendableSats: UInt64,
        onchainSpendableSats: UInt64
    ) async throws -> PaykitRoute {
        let serviceLegs = source == .spending && route.offersSparkLeg
            ? await sparkLegs(to: route.onchainEndpoints, amountSats: amountSats)
            : []
        return try paykitRoutePayment(
            request: request(
                route: route,
                amountSats: amountSats,
                source: source,
                lightningSpendableSats: lightningSpendableSats,
                onchainSpendableSats: onchainSpendableSats,
                serviceLegs: serviceLegs
            ),
            network: Env.bitkitCoreNetwork
        )
    }

    private static func sparkLegs(to endpoints: [PaykitEndpoint], amountSats: UInt64) async -> [ServiceRouteLeg] {
        var legs: [ServiceRouteLeg] = []
        for endpoint in endpoints {
            do {
                if let leg = try await SparkManager.shared.withdrawalRouteLeg(endpoint: endpoint, amountSats: amountSats) {
                    legs.append(leg)
                }
            } catch {
                Logger.warn("No Spark route to \(endpoint.methodId): \(error)", context: "PaykitRoute")
            }
        }
        return legs
    }

    /// Whether a None route is a short balance rather than a contact Bitkit can't pay.
    static func isBalanceShort(amountSats: UInt64, lightningSpendableSats: UInt64, onchainSpendableSats: UInt64) -> Bool {
        amountSats > lightningSpendableSats.saturatingAdd(onchainSpendableSats)
    }

    /// Runs a service leg the router picked and returns the txid that pays the contact.
    /// Whether a failed leg send releases this call's started proof: only when Spark refused it before sending, and no
    /// open journal of the same request (an earlier attempt that may have paid) still owns that proof. Another
    /// request's open journal never decides it.
    static func legFailureReleasesProof(
        _ error: Error,
        openJournalRequest: SparkContactWithdrawal.PaykitRequest?,
        proofRequest: SparkContactWithdrawal.PaykitRequest
    ) -> Bool {
        error is SparkWithdrawalNotSent && openJournalRequest != proofRequest
    }

    /// Starts the on-chain proof of a request a Spark leg pays, in a direct send's order: the proof is prepared, then the
    /// request (its checks and private list consumption), then the proof is marked started. Any failure releases the
    /// private payment list as unsent, and one after the proof was prepared cancels it, so the request can be paid again.
    static func startLegRequestProof(
        prepareProof: () async throws -> Void,
        prepareRequest: () async throws -> Void,
        paymentIdentity: () async throws -> String,
        markStarted: (String) async throws -> Void,
        cancelProof: () async -> Void,
        releasePaymentList: () async -> Void
    ) async throws -> String {
        do {
            try await prepareProof()
        } catch {
            await releasePaymentList()
            throw error
        }
        do {
            try await prepareRequest()
            let identity = try await paymentIdentity()
            try await markStarted(identity)
            return identity
        } catch {
            await cancelProof()
            await releasePaymentList()
            throw error
        }
    }

    static func pay(
        _ leg: ServiceRouteLeg,
        contact: String?,
        request: SparkContactWithdrawal.PaykitRequest? = nil,
        tags: [String] = [],
        beforeSend: () async throws -> Void = {}
    ) async throws -> String {
        guard leg.service == SparkManager.routeService else {
            throw AppError(message: "wallet__payment_failed_description", debugMessage: "Unsupported route service \(leg.service)")
        }
        return try await SparkManager.shared.withdraw(
            to: leg.endpoint.value,
            amountSats: leg.deliveredSat,
            contact: contact,
            request: request,
            tags: tags,
            maxFeeSats: leg.debitSat.saturatingSub(leg.deliveredSat),
            beforeSend: beforeSend
        )
    }
}

/// What asking the router did to a contact payment.
enum PaykitRouteOutcome: Equatable {
    /// The send pays the endpoint the router picked.
    case direct
    /// The send pays through the service leg in `AppViewModel.paykitRoute`.
    case leg
    /// No route pays the contact; the app's copy says why.
    case refused
}

@MainActor
extension AppViewModel {
    /// Asks bitkit-core's router how to pay the contact from `source`. Direct switches the send to the endpoint it
    /// names, a service leg is kept in `paykitRoute` for Confirm, and none shows the app's copy, its reason going to the
    /// log only.
    func routeContactPayment(
        _ route: PaykitRouteUi,
        amountSats: UInt64,
        source: PaykitRouteService.Source,
        lightningSpendableSats: UInt64,
        onchainSpendableSats: UInt64,
        request: PaykitPaymentRequest?
    ) async -> PaykitRouteOutcome {
        var unrouted = route
        unrouted.serviceLeg = nil
        do {
            let picked = try await PaykitRouteService.route(
                route,
                amountSats: amountSats,
                source: source,
                lightningSpendableSats: lightningSpendableSats,
                onchainSpendableSats: onchainSpendableSats
            )
            switch picked {
            case let .direct(endpoint):
                paykitRoute = unrouted
                guard await payDirectly(endpoint) else { return .refused }
                if let request {
                    paykitPaymentTerms = try request.payment(using: paykitPaymentMethod)
                }
                return .direct
            case let .service(leg):
                var routed = route
                routed.serviceLeg = leg
                paykitRoute = routed
                selectedWalletToPayFrom = .lightning
                return .leg
            case let .none(reason):
                Logger.warn("Found no Paykit route: '\(reason)'", context: "PaykitRoute")
                paykitRoute = unrouted
                showNoPaykitRouteToast(isBalanceShort: PaykitRouteService.isBalanceShort(
                    amountSats: amountSats,
                    lightningSpendableSats: lightningSpendableSats,
                    onchainSpendableSats: onchainSpendableSats
                ))
                return .refused
            }
        } catch {
            Logger.error("Failed to route Paykit payment: \(error)", context: "PaykitRoute")
            showNoPaykitRouteToast(isBalanceShort: false)
            return .refused
        }
    }

    /// Switches the send to the endpoint the router picked, when the scan opened another one.
    private func payDirectly(_ endpoint: PaykitEndpoint) async -> Bool {
        if endpoint.isOnchain {
            selectedWalletToPayFrom = .onchain
            if scannedOnchainInvoice?.address != endpoint.value {
                scannedOnchainInvoice = OnChainInvoice(address: endpoint.value, amountSatoshis: 0, label: nil, message: nil, params: nil)
            }
            return true
        }
        selectedWalletToPayFrom = .lightning
        if endpoint.isLnurl {
            return lnurlPayData != nil || scannedLightningInvoice != nil
        }
        if scannedLightningInvoice?.bolt11.caseInsensitiveCompare(endpoint.value) == .orderedSame {
            return true
        }
        guard case let .lightning(invoice) = try? await decode(invoice: endpoint.value) else {
            Logger.warn("Failed to decode the Lightning endpoint the router picked", context: "PaykitRoute")
            showNoPaykitRouteToast(isBalanceShort: false)
            return false
        }
        scannedLightningInvoice = invoice
        lnurlPayData = nil
        return true
    }

    func showNoPaykitRouteToast(isBalanceShort: Bool) {
        toast(
            type: .error,
            title: t(isBalanceShort ? "wallet__send_amount_exceeded__title" : "wallet__send_paykit_no_route__title"),
            description: t(isBalanceShort ? "wallet__send_amount_exceeded__description" : "wallet__send_paykit_no_route__description"),
            accessibilityIdentifier: isBalanceShort ? "PaykitRouteBalanceToast" : "PaykitRouteNoneToast"
        )
    }
}
