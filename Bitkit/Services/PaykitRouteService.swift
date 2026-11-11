import BitkitCore
import Foundation
import Paykit

/// A contact payment bitkit-core's Paykit router picks the way for: the contact's bitcoin endpoints, whether a Spark leg
/// may reach its on-chain ones, the leg once the router picked one, and the decoded invoice and LNURL a Direct pick pays.
struct PaykitRouteUi: Equatable {
    let endpoints: [PaykitEndpoint]
    let offersSparkLeg: Bool
    var serviceLeg: ServiceRouteLeg?
    var invoice: LightningInvoice?
    var lnurl: LnurlPayData?

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

    /// Whether a Spark withdrawal carries `amountSats` on `route`, or nil when Lightning's limit decides. A withdrawal
    /// is paid from Spark's whole balance, so Lightning's limit never caps it: a quoted leg fits when its debit, fees
    /// included, does, and before the quote an amount the balance covers lets Continue ask for one.
    static func sparkWithdrawalValidity(route: PaykitRouteUi?, amountSats: UInt64, sparkBalanceSats: UInt64) -> Bool? {
        guard let route, route.offersSparkLeg, amountSats > 0 else { return nil }
        if let leg = route.serviceLeg, leg.deliveredSat == amountSats {
            return sparkBalanceSats >= leg.debitSat
        }
        return sparkBalanceSats >= amountSats ? true : nil
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

    /// Prepares the on-chain proof of a request a Spark leg pays, in a direct send's order: the proof is prepared, then
    /// the request (its checks and private list consumption). Spark's withdrawal marks the proof started once its journal
    /// is written. Any failure releases the private payment list as unsent, and one after the proof was prepared cancels
    /// it, so the request can be paid again.
    static func startLegRequestProof(
        prepareProof: () async throws -> Void,
        prepareRequest: () async throws -> Void,
        paymentIdentity: () async throws -> String,
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
            return try await paymentIdentity()
        } catch {
            await cancelProof()
            await releasePaymentList()
            throw error
        }
    }

    /// Pays a leg as a manual payment the allowance ledger counts, as a direct send is: the attempt is reserved right
    /// before Spark's send, marked sending once the request is authorized, and closed with the send's outcome:
    /// succeeded with its txid, failed when Spark refused it before sending, and unknown otherwise.
    static func payReportingAllowance(
        beginAllowance: @escaping () async throws -> String?,
        authorize: @escaping () async throws -> Void,
        markSending: @escaping (String) async -> Void,
        finishAllowance: (String, Paykit.PaymentOutcome, String?) async -> Void,
        pay: (_ beforeSend: () async throws -> Void) async throws -> String
    ) async throws -> String {
        var attemptId: String?
        do {
            let txid = try await pay {
                attemptId = try await beginAllowance()
                try await authorize()
                if let attemptId {
                    await markSending(attemptId)
                }
            }
            if let attemptId {
                await finishAllowance(attemptId, .succeeded, txid)
            }
            return txid
        } catch {
            if let attemptId {
                await finishAllowance(attemptId, error is SparkWithdrawalNotSent ? .failed : .unknown, nil)
            }
            throw error
        }
    }

    static func pay(
        _ leg: ServiceRouteLeg,
        contact: String?,
        request: SparkContactWithdrawal.PaykitRequest? = nil,
        tags: [String] = [],
        paymentDeadline: PaykitPreciseInstant? = nil,
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
            paymentDeadline: paymentDeadline,
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
    /// The payment changed while the router answered, so its answer was dropped.
    case stale
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
        request: PaykitPaymentRequest?,
        router: (PaykitRouteUi, UInt64, PaykitRouteService.Source, UInt64, UInt64) async throws -> PaykitRoute = PaykitRouteService.route
    ) async -> PaykitRouteOutcome {
        var unrouted = route
        unrouted.serviceLeg = nil
        unrouted.invoice = route.invoice ?? scannedLightningInvoice
        unrouted.lnurl = route.lnurl ?? lnurlPayData
        let contactId = contactPaymentContext?.id
        paykitRoutingGeneration += 1
        let generation = paykitRoutingGeneration
        // A dismissed or replaced payment, a newer routing request (a new amount or source) or a source picked since
        // makes the answer stale, so it never lands on what followed it.
        let isCurrent = {
            self.contactPaymentContext?.id == contactId && self.paykitRoutingGeneration == generation &&
                (self.selectedWalletToPayFrom == .lightning) == (source == .spending) &&
                (self.paykitRoute.map { $0.endpoints == route.endpoints } ?? true)
        }
        do {
            let picked = try await router(route, amountSats, source, lightningSpendableSats, onchainSpendableSats)
            guard isCurrent() else { return .stale }
            switch picked {
            case let .direct(endpoint):
                paykitRoute = unrouted
                guard await payDirectly(endpoint, route: unrouted) else { return .refused }
                if let request {
                    paykitPaymentTerms = try request.payment(using: paykitPaymentMethod)
                }
                return .direct
            case let .service(leg):
                var routed = unrouted
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
            guard isCurrent() else { return .stale }
            showNoPaykitRouteToast(isBalanceShort: false)
            return .refused
        }
    }

    /// Switches the send to exactly the endpoint the router picked, clearing the other Lightning one. An earlier pick may
    /// have cleared the picked one, so it comes back from `route`.
    private func payDirectly(_ endpoint: PaykitEndpoint, route: PaykitRouteUi) async -> Bool {
        if endpoint.isOnchain {
            selectedWalletToPayFrom = .onchain
            if scannedOnchainInvoice?.address != endpoint.value {
                scannedOnchainInvoice = OnChainInvoice(address: endpoint.value, amountSatoshis: 0, label: nil, message: nil, params: nil)
            }
            return true
        }
        selectedWalletToPayFrom = .lightning
        if endpoint.isLnurl {
            guard let lnurl = lnurlPayData ?? route.lnurl else {
                Logger.warn("Found no LNURL for the endpoint the router picked", context: "PaykitRoute")
                showNoPaykitRouteToast(isBalanceShort: false)
                return false
            }
            lnurlPayData = lnurl
            scannedLightningInvoice = nil
            return true
        }
        let known = [scannedLightningInvoice, route.invoice].compactMap { $0 }
            .first { $0.bolt11.caseInsensitiveCompare(endpoint.value) == .orderedSame }
        if let known {
            scannedLightningInvoice = known
        } else {
            guard case let .lightning(invoice) = try? await decode(invoice: endpoint.value) else {
                Logger.warn("Failed to decode the Lightning endpoint the router picked", context: "PaykitRoute")
                showNoPaykitRouteToast(isBalanceShort: false)
                return false
            }
            scannedLightningInvoice = invoice
        }
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
