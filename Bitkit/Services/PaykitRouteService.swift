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
    /// on-chain endpoint while Spark can route, whatever Lightning can pay, since the router still picks a direct payment
    /// that works; a request it pays gets its on-chain proof from the withdrawal's txid.
    static func routeUi(for context: ContactPaymentContext, canRouteThroughSpark: Bool) -> PaykitRouteUi? {
        let endpoints = context.endpoints
            .filter { $0.methodId != .usdtArbitrum }
            .map { PaykitEndpoint(methodId: $0.methodId.rawValue, value: $0.value) }
        guard !endpoints.isEmpty else { return nil }
        let offersSparkLeg = canRouteThroughSpark && endpoints.contains(where: \.isOnchain)
        return PaykitRouteUi(endpoints: endpoints, offersSparkLeg: offersSparkLeg)
    }

    /// What the router is asked from `source`: Spending offers every endpoint but an LNURL whose limits refuse the amount,
    /// Savings only the on-chain ones.
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
                contactEndpoints: route.endpoints.filter { !$0.isLnurl || route.lnurl?.accepts(amountSats: amountSats) != false },
                lightningSpendableSat: lightningSpendableSats,
                onchainSpendableSat: 0,
                serviceLegs: serviceLegs,
                // Only bitkit-core's Pubky Swaps route reads these, and the app never asks it, so no swap comes back.
                providers: [],
                feeRateSatVb: 0
            )
        case .savings:
            PaykitRouteRequest(
                amountSat: amountSats,
                contactEndpoints: route.onchainEndpoints,
                lightningSpendableSat: 0,
                onchainSpendableSat: onchainSpendableSats,
                serviceLegs: [],
                providers: [],
                feeRateSatVb: 0
            )
        }
    }

    /// Asks the router how to pay `amountSats` from `source`. The router pays directly before it weighs any leg, so a
    /// Spark leg to each on-chain endpoint is quoted only when the route offers one and no balance pays. Spark takes one
    /// contact withdrawal at a time, so while an earlier one's journal is open no leg is quoted and this throws
    /// `SparkWithdrawalSettling`.
    static func route(
        _ route: PaykitRouteUi,
        amountSats: UInt64,
        source: Source,
        lightningSpendableSats: UInt64,
        onchainSpendableSats: UInt64,
        quoteLegs: ([PaykitEndpoint], UInt64) async throws -> [ServiceRouteLeg] = { try await sparkLegs(to: $0, amountSats: $1) }
    ) async throws -> PaykitRoute {
        func pick(_ serviceLegs: [ServiceRouteLeg]) throws -> PaykitRoute {
            try paykitRoutePayment(
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
        let direct = try pick([])
        guard case .none = direct, source == .spending, route.offersSparkLeg else { return direct }
        guard SparkManager.pendingContactWithdrawal == nil else { throw SparkWithdrawalSettling() }
        let serviceLegs = try await quoteLegs(route.onchainEndpoints, amountSats)
        return serviceLegs.isEmpty ? direct : try pick(serviceLegs)
    }

    /// Spark's leg to each of `endpoints`, from `quote`. Throws `SparkLegUnaffordable` when no leg is quoted and one
    /// was dropped because Spark's balance can't cover the amount and its fee.
    static func sparkLegs(
        to endpoints: [PaykitEndpoint],
        amountSats: UInt64,
        quote: (PaykitEndpoint, UInt64) async throws -> ServiceRouteLeg? = {
            try await SparkManager.shared.withdrawalRouteLeg(endpoint: $0, amountSats: $1)
        }
    ) async throws -> [ServiceRouteLeg] {
        var legs: [ServiceRouteLeg] = []
        var unaffordable: SparkLegUnaffordable?
        for endpoint in endpoints {
            do {
                if let leg = try await quote(endpoint, amountSats) {
                    legs.append(leg)
                }
            } catch {
                unaffordable = unaffordable ?? error as? SparkLegUnaffordable
                Logger.warn("No Spark route to \(endpoint.methodId): \(error)", context: "PaykitRoute")
            }
        }
        if legs.isEmpty, let unaffordable {
            throw unaffordable
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

/// Only a Spark leg could pay, but an earlier contact withdrawal's journal is still open.
struct SparkWithdrawalSettling: Error {}

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
    /// No balance or Spark leg pays it, and the caller has a Pubky Swaps route to try instead, so nothing was shown.
    case swapFallback
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
        hasSwapFallback: Bool = false,
        router: (PaykitRouteUi, UInt64, PaykitRouteService.Source, UInt64, UInt64) async throws -> PaykitRoute = {
            try await PaykitRouteService.route($0, amountSats: $1, source: $2, lightningSpendableSats: $3, onchainSpendableSats: $4)
        },
        decodeEndpoint: (String) async throws -> BitkitCore.Scanner = { try await decode(invoice: $0) }
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
        // A short balance names itself first, then the limit of an LNURL that refused the amount (the router never saw
        // it), then a Spark leg the balance can't cover with its fee.
        func refuse(sparkLegShort: Bool) -> PaykitRouteOutcome {
            paykitRoute = unrouted
            let isBalanceShort = PaykitRouteService.isBalanceShort(
                amountSats: amountSats,
                lightningSpendableSats: lightningSpendableSats,
                onchainSpendableSats: onchainSpendableSats
            )
            if isBalanceShort || unrouted.lnurl.map({ validateLnurlAmount($0, amountSats: amountSats) }) != false {
                showNoPaykitRouteToast(isBalanceShort: isBalanceShort || sparkLegShort)
            }
            return .refused
        }
        let isCurrent = {
            self.contactPaymentContext?.id == contactId && self.paykitRoutingGeneration == generation &&
                (self.selectedWalletToPayFrom == .lightning) == (source == .spending) &&
                (self.paykitRoute.map { $0.endpoints == route.endpoints } ?? true)
        }
        do {
            // The known invoice and LNURL go to the router too, so it never picks an LNURL whose limits refuse the amount.
            let picked = try await router(unrouted, amountSats, source, lightningSpendableSats, onchainSpendableSats)
            guard isCurrent() else { return .stale }
            switch picked {
            case let .direct(endpoint):
                paykitRoute = unrouted
                // A decode is a network fetch for an LNURL: the send it was for can change while it runs.
                guard let paid = await payDirectly(endpoint, route: unrouted, decode: decodeEndpoint, isCurrent: isCurrent) else {
                    return .stale
                }
                guard paid else { return .refused }
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
                if hasSwapFallback {
                    paykitRoute = unrouted
                    return .swapFallback
                }
                return refuse(sparkLegShort: false)
            case .swap:
                // The app never offers Pubky Swaps providers, so a swap route can't come back; it pays nothing either.
                Logger.warn("Found no Paykit route: 'Swap routes are unsupported'", context: "PaykitRoute")
                return refuse(sparkLegShort: false)
            }
        } catch is SparkWithdrawalSettling {
            Logger.warn("Found no Paykit route: an earlier Spark contact withdrawal is still settling", context: "PaykitRoute")
            guard isCurrent() else { return .stale }
            // A short balance and an LNURL limit name themselves first, as for any other refusal.
            let lnurlRefuses = unrouted.lnurl.map { !$0.accepts(amountSats: amountSats) } ?? false
            if lnurlRefuses || PaykitRouteService.isBalanceShort(
                amountSats: amountSats,
                lightningSpendableSats: lightningSpendableSats,
                onchainSpendableSats: onchainSpendableSats
            ) {
                return refuse(sparkLegShort: false)
            }
            paykitRoute = unrouted
            toast(
                type: .error,
                title: t("wallet__send_paykit_no_route__title"),
                description: t("wallet__send_paykit_withdrawal_settling__description"),
                accessibilityIdentifier: "PaykitRouteSettlingToast"
            )
            return .refused
        } catch let error as SparkLegUnaffordable {
            Logger.warn("Found no Paykit route: \(error)", context: "PaykitRoute")
            guard isCurrent() else { return .stale }
            // A Spark balance too small for the amount and fee leaves the payment to a swap provider when one can carry it.
            if hasSwapFallback {
                paykitRoute = unrouted
                return .swapFallback
            }
            return refuse(sparkLegShort: true)
        } catch {
            Logger.error("Failed to route Paykit payment: \(error)", context: "PaykitRoute")
            guard isCurrent() else { return .stale }
            showNoPaykitRouteToast(isBalanceShort: false)
            return .refused
        }
    }

    /// Switches the send to exactly the endpoint the router picked, clearing the other Lightning one. An earlier pick may
    /// have cleared the picked one, so it comes back from `route`; one never decoded is decoded here. Returns false when
    /// it cannot pay the endpoint, and nil when the send changed during a decode, writing nothing.
    private func payDirectly(
        _ endpoint: PaykitEndpoint,
        route: PaykitRouteUi,
        decode: (String) async throws -> BitkitCore.Scanner,
        isCurrent: () -> Bool
    ) async -> Bool? {
        if endpoint.isOnchain {
            selectedWalletToPayFrom = .onchain
            if scannedOnchainInvoice?.address != endpoint.value {
                scannedOnchainInvoice = OnChainInvoice(address: endpoint.value, amountSatoshis: 0, label: nil, message: nil, params: nil)
            }
            return true
        }
        selectedWalletToPayFrom = .lightning
        if endpoint.isLnurl {
            if let lnurl = lnurlPayData ?? route.lnurl {
                lnurlPayData = lnurl
            } else {
                // A route built once Spark became ready after the scan holds the contact's LNURL undecoded.
                let decoded = try? await decode(endpoint.value)
                guard isCurrent() else { return nil }
                guard case let .lnurlPay(data) = decoded else {
                    Logger.warn("Failed to decode the LNURL endpoint the router picked", context: "PaykitRoute")
                    showNoPaykitRouteToast(isBalanceShort: false)
                    return false
                }
                lnurlPayData = data
                paykitRoute?.lnurl = data
            }
            scannedLightningInvoice = nil
            return true
        }
        let known = [scannedLightningInvoice, route.invoice].compactMap { $0 }
            .first { $0.bolt11.caseInsensitiveCompare(endpoint.value) == .orderedSame }
        if let known {
            scannedLightningInvoice = known
        } else {
            let decoded = try? await decode(endpoint.value)
            guard isCurrent() else { return nil }
            guard case let .lightning(invoice) = decoded else {
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

    /// The route can restore an LNURL a BOLT11 pick cleared, so Amount checks its limits after routing.
    func validateRoutedLnurlAmount(amountSats: UInt64) -> Bool {
        guard let lnurlPayData else { return true }
        return validateLnurlAmount(lnurlPayData, amountSats: amountSats)
    }

    /// Shows `lnurl`'s too-low or too-high toast when `amountSats` is outside its limits; true when it accepts it.
    func validateLnurlAmount(_ lnurlPayData: LnurlPayData, amountSats: UInt64) -> Bool {
        guard !lnurlPayData.accepts(amountSats: amountSats) else { return true }
        let minimumAmount = max(1, lnurlPayData.minSendableSat)
        if amountSats < minimumAmount {
            toast(
                type: .error,
                title: t("wallet__lnurl_pay__error_min__title"),
                description: t(
                    "wallet__lnurl_pay__error_min__description",
                    variables: ["amount": CurrencyFormatter.formatSats(minimumAmount)]
                ),
                accessibilityIdentifier: "LnurlPayAmountTooLowToast"
            )
        } else {
            toast(
                type: .error,
                title: t("wallet__lnurl_pay__error_max__title"),
                description: t("wallet__lnurl_pay__error_max__description"),
                accessibilityIdentifier: "LnurlPayAmountTooHighToast"
            )
        }
        return false
    }
}
