import BitkitCore
import Foundation
import LDKNode
import Paykit

enum PublicPaykitError: LocalizedError {
    case noSupportedEndpoint
    case walletNotReady
    case invalidPayload
    case routeHintsUnavailable
    case publicationFailed

    var errorDescription: String? {
        switch self {
        case .noSupportedEndpoint:
            return "No supported public payment endpoint is available."
        case .walletNotReady:
            return "Bitkit could not prepare a public payment endpoint because the wallet is not ready."
        case .invalidPayload:
            return "The public payment endpoint payload is invalid."
        case .routeHintsUnavailable:
            return "A reachable Lightning payment endpoint is not available yet."
        case .publicationFailed:
            return "Bitkit could not publish Paykit payment endpoints."
        }
    }
}

struct PrivatePaykitPaymentContext: Equatable {
    let paymentAppsByEndpoint: [String: String]
    let paymentListVersion: UInt64?

    func paymentAppId(for endpointIdentifier: String) throws -> String {
        guard let appId = paymentAppsByEndpoint[endpointIdentifier] else { throw PaykitPaymentRequestError.requestUnavailable }
        return appId
    }
}

struct PrivatePaykitAllowancePayment: Equatable {
    let endpoint: PublicPaykitService.Endpoint
    let context: PrivatePaykitPaymentContext
    let lightningPaymentHash: String?
    let lightningInvoiceHasAmount: Bool
}

enum IncomingPaykitPaymentRequestFailureReason: String, Hashable {
    case noSupportedEndpoint = "no_supported_endpoint"
    case endpointNotPayable = "endpoint_not_payable"
    case paymentDetailsPending = "payment_details_pending"
    case invalidPaymentTarget = "invalid_payment_target"
    case paymentTargetNotRoutable = "payment_target_not_routable"
    case requestExpired = "request_expired"
    case resolutionFailed = "resolution_failed"

    var category: String {
        switch self {
        case .noSupportedEndpoint, .endpointNotPayable, .paymentDetailsPending, .resolutionFailed:
            "resolution"
        case .invalidPaymentTarget, .paymentTargetNotRoutable, .requestExpired:
            "presentation"
        }
    }
}

enum PublicPaykitPaymentLaunchResult {
    case opened(paymentRequest: String, privatePaymentContext: PrivatePaykitPaymentContext?, endpoints: [PublicPaykitService.Endpoint] = [])
    case noEndpoint
    case notOpened
    case privateLinkPending
    case waitingForUpdatedPaymentList

    var contactPaymentFailureMessageKey: String? {
        switch self {
        case .opened:
            nil
        case .noEndpoint, .privateLinkPending, .waitingForUpdatedPaymentList:
            "slashtags__error_pay_empty_msg"
        case .notOpened:
            "slashtags__error_pay_not_opened_msg"
        }
    }

    var incomingPaymentRequestFailureReason: IncomingPaykitPaymentRequestFailureReason? {
        switch self {
        case .opened:
            nil
        case .noEndpoint:
            .noSupportedEndpoint
        case .notOpened:
            .endpointNotPayable
        case .privateLinkPending, .waitingForUpdatedPaymentList:
            .paymentDetailsPending
        }
    }
}

private actor PublicPaykitEndpointLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: () async throws -> T) async throws -> T {
        await lock()
        defer { unlock() }
        return try await operation()
    }

    private func lock() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func unlock() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }

        waiters.removeFirst().resume()
    }
}

enum PublicPaykitService {
    private static let endpointLock = PublicPaykitEndpointLock()
    static let publishingEnabledKey = "sharesPublicPaykitEndpoints"
    static let lightningPaymentOptionEnabledKey = "paykitPaymentOptionLightningEnabled"
    static let onchainPaymentOptionEnabledKey = "paykitPaymentOptionOnchainEnabled"
    static let usdtPaymentOptionEnabledKey = "paykitPaymentOptionUsdtEnabled"
    static let cleanupPendingKey = "publicPaykitCleanupPending"
    static let reconciliationRevisionKey = "publicPaykitReconciliationRevision"
    private static let reconciliationLock = NSLock()

    static func setCleanupPending(_ isPending: Bool) {
        reconciliationLock.withLock {
            UserDefaults.standard.set(isPending, forKey: cleanupPendingKey)
        }
    }

    static func clearRemovedProfileReconciliation() {
        reconciliationLock.withLock {
            UserDefaults.standard.set(false, forKey: cleanupPendingKey)
            UserDefaults.standard.removeObject(forKey: reconciliationRevisionKey)
        }
    }

    static func queueEndpointReconciliation() {
        reconciliationLock.withLock {
            UserDefaults.standard.set(UUID().uuidString, forKey: reconciliationRevisionKey)
            UserDefaults.standard.set(true, forKey: cleanupPendingKey)
        }
    }

    private static var reconciliationRevision: String? {
        reconciliationLock.withLock { UserDefaults.standard.string(forKey: reconciliationRevisionKey) }
    }

    private static func acknowledgeReconciliation(revision: String?) {
        reconciliationLock.withLock {
            let matches = UserDefaults.standard.string(forKey: reconciliationRevisionKey) == revision
            UserDefaults.standard.set(!matches, forKey: cleanupPendingKey)
        }
    }

    static var isCleanupPending: Bool {
        UserDefaults.standard.bool(forKey: cleanupPendingKey)
    }

    enum PendingReconciliationMode: Equatable {
        case publishEndpoints
        case removePublishedState
    }

    static func pendingReconciliationMode(defaults: UserDefaults = .standard) -> PendingReconciliationMode {
        if defaults.bool(forKey: publishingEnabledKey) {
            return .publishEndpoints
        }
        return .removePublishedState
    }

    enum MethodId: String, Hashable, CaseIterable {
        case usdtArbitrum = "usdt-arbitrum-address"
        case bitcoinLightningBolt11 = "btc-lightning-bolt11"
        case bitcoinLightningLnurl = "btc-lightning-lnurl"
        case bitcoinOnchainP2tr = "btc-bitcoin-p2tr"
        case bitcoinOnchainP2wpkh = "btc-bitcoin-p2wpkh"
        case bitcoinOnchainP2sh = "btc-bitcoin-p2sh"
        case bitcoinOnchainP2pkh = "btc-bitcoin-p2pkh"
        case testnetOnchainP2tr = "btc-testnet-p2tr"
        case testnetOnchainP2wpkh = "btc-testnet-p2wpkh"
        case testnetOnchainP2sh = "btc-testnet-p2sh"
        case testnetOnchainP2pkh = "btc-testnet-p2pkh"
        case signetOnchainP2tr = "btc-signet-p2tr"
        case signetOnchainP2wpkh = "btc-signet-p2wpkh"
        case signetOnchainP2sh = "btc-signet-p2sh"
        case signetOnchainP2pkh = "btc-signet-p2pkh"
        case regtestOnchainP2tr = "btc-regtest-p2tr"
        case regtestOnchainP2wpkh = "btc-regtest-p2wpkh"
        case regtestOnchainP2sh = "btc-regtest-p2sh"
        case regtestOnchainP2pkh = "btc-regtest-p2pkh"

        static let payablePreferenceOrder: [MethodId] = [
            .bitcoinLightningBolt11,
            .bitcoinLightningLnurl,
        ] + onchainPreferenceOrder + [.usdtArbitrum]

        static let publishableMethodIds: [MethodId] = [
            .bitcoinLightningBolt11,
        ] + onchainPreferenceOrder + [.usdtArbitrum]

        static let onchainPreferenceOrder: [MethodId] = [
            .bitcoinOnchainP2tr,
            .testnetOnchainP2tr,
            .signetOnchainP2tr,
            .regtestOnchainP2tr,
            .bitcoinOnchainP2wpkh,
            .testnetOnchainP2wpkh,
            .signetOnchainP2wpkh,
            .regtestOnchainP2wpkh,
            .bitcoinOnchainP2sh,
            .testnetOnchainP2sh,
            .signetOnchainP2sh,
            .regtestOnchainP2sh,
            .bitcoinOnchainP2pkh,
            .testnetOnchainP2pkh,
            .signetOnchainP2pkh,
            .regtestOnchainP2pkh,
        ]

        var onchainNetwork: LDKNode.Network? {
            switch self {
            case .bitcoinOnchainP2tr, .bitcoinOnchainP2wpkh, .bitcoinOnchainP2sh, .bitcoinOnchainP2pkh:
                .bitcoin
            case .testnetOnchainP2tr, .testnetOnchainP2wpkh, .testnetOnchainP2sh, .testnetOnchainP2pkh:
                .testnet
            case .signetOnchainP2tr, .signetOnchainP2wpkh, .signetOnchainP2sh, .signetOnchainP2pkh:
                .signet
            case .regtestOnchainP2tr, .regtestOnchainP2wpkh, .regtestOnchainP2sh, .regtestOnchainP2pkh:
                .regtest
            case .bitcoinLightningBolt11, .bitcoinLightningLnurl, .usdtArbitrum:
                nil
            }
        }

        static func onchainMethodId(network: LDKNode.Network, scriptType: OnchainScriptType) -> MethodId {
            switch (network, scriptType) {
            case (.bitcoin, .p2tr): .bitcoinOnchainP2tr
            case (.bitcoin, .p2wpkh): .bitcoinOnchainP2wpkh
            case (.bitcoin, .p2sh): .bitcoinOnchainP2sh
            case (.bitcoin, .p2pkh): .bitcoinOnchainP2pkh
            case (.testnet, .p2tr): .testnetOnchainP2tr
            case (.testnet, .p2wpkh): .testnetOnchainP2wpkh
            case (.testnet, .p2sh): .testnetOnchainP2sh
            case (.testnet, .p2pkh): .testnetOnchainP2pkh
            case (.signet, .p2tr): .signetOnchainP2tr
            case (.signet, .p2wpkh): .signetOnchainP2wpkh
            case (.signet, .p2sh): .signetOnchainP2sh
            case (.signet, .p2pkh): .signetOnchainP2pkh
            case (.regtest, .p2tr): .regtestOnchainP2tr
            case (.regtest, .p2wpkh): .regtestOnchainP2wpkh
            case (.regtest, .p2sh): .regtestOnchainP2sh
            case (.regtest, .p2pkh): .regtestOnchainP2pkh
            }
        }
    }

    enum OnchainScriptType {
        case p2tr
        case p2wpkh
        case p2sh
        case p2pkh
    }

    struct Endpoint: Equatable, Hashable {
        let methodId: MethodId
        let value: String
        let min: String?
        let max: String?
        let rawPayload: String
        var appId: String?

        var paymentRequest: String {
            methodId == .usdtArbitrum ? PaykitUsdt.paymentURI(address: value) : value
        }
    }

    static func fetchPublicEndpoints(publicKey: String) async throws -> [Endpoint] {
        let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) ?? publicKey
        let resolution = try await PaykitSdkService.shared.resolvePublicContactPayment(
            counterparty: normalizedKey
        )
        let endpoints = resolution.payableEndpoints.compactMap { resolvedEndpoint -> Endpoint? in
            guard var endpoint = parseEndpoint(identifier: resolvedEndpoint.identifier, payload: resolvedEndpoint.target.payload) else { return nil }
            endpoint.appId = resolvedEndpoint.appId
            return endpoint
        }
        return MethodId.payablePreferenceOrder.flatMap { method in endpoints.filter { $0.methodId == method } }
    }

    static func parseEndpoint(
        methodId rawMethodId: String,
        endpointData: String,
        network: LDKNode.Network = Env.network
    ) -> Endpoint? {
        guard let methodId = MethodId(rawValue: rawMethodId) else {
            return nil
        }
        if let onchainNetwork = methodId.onchainNetwork, onchainNetwork != network {
            return nil
        }

        guard let payload = PaykitIssuerInterop.parseEndpointPayload(endpointData) else {
            return nil
        }
        if methodId == .usdtArbitrum, PaykitUsdt.address(from: endpointData) == nil {
            return nil
        }

        return Endpoint(
            methodId: methodId,
            value: payload.value,
            min: payload.min,
            max: payload.max,
            rawPayload: endpointData
        )
    }

    static func parseEndpoint(identifier: String, payload: PaymentPayload) -> Endpoint? {
        parseEndpoint(methodId: identifier, endpointData: payload.exportText())
    }

    static func parseEndpoint(candidate: PublicPaymentEndpointCandidate) -> Endpoint? {
        parseEndpoint(identifier: candidate.identifier, payload: candidate.payload)
    }

    static func parseEndpoint(candidate: PrivatePaymentEndpointCandidate) -> Endpoint? {
        parseEndpoint(identifier: candidate.identifier, payload: candidate.payload)
    }

    static func serializePayload(value: String) throws -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            throw PublicPaykitError.invalidPayload
        }

        let payload = ["value": trimmedValue]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw PublicPaykitError.invalidPayload
        }
        return json
    }

    @MainActor
    static func syncPublishedEndpoints(
        wallet: WalletViewModel,
        publish: Bool,
        isSessionCurrent: (@MainActor () -> Bool)? = nil,
        appSyncPriority: PaykitSdkOperationLock.Priority = .ordered,
        syncApp: (() async throws -> Void)? = nil,
        applyEndpoints: (([Endpoint]) async throws -> Void)? = nil
    ) async throws {
        try await ProfileOperationAdmission.shared.withOperation {
            if let isSessionCurrent, !isSessionCurrent() {
                throw PubkyServiceError.sessionNotActive
            }
            let session = wallet.publicPaykitSession
            if publish {
                wallet.preparePendingPublicPaykitInvoiceRefresh()
            }
            let pendingRevision = reconciliationRevision
            var desiredSnapshot: (
                endpoints: [Endpoint],
                invoiceRevision: UUID,
                publicAddress: PrivatePaykitAddressReservationStore.PublicAddressSnapshot?
            )?
            let apply = applyEndpoints ?? { try await applyPublishedEndpointsLocked($0, isSessionCurrent: isSessionCurrent) }
            try await syncPublishedEndpoints(
                publish: publish,
                isSessionCurrent: isSessionCurrent,
                buildEndpoints: {
                    let snapshot = try await buildWalletEndpoints(wallet: wallet, session: session, refreshIfNeeded: true, requireEndpoint: true)
                    desiredSnapshot = snapshot
                    return snapshot.endpoints
                },
                syncApp: syncApp ?? { try await syncPaykitApp(priority: appSyncPriority, isSessionCurrent: isSessionCurrent) },
                applyEndpoints: { endpoints in
                    if publish {
                        markPublicationPending(wallet: wallet, session: session, isSessionCurrent: isSessionCurrent)
                    }
                    try await apply(endpoints)
                },
                onPublished: {
                    if let desiredSnapshot {
                        acknowledgePublishedEndpoints(
                            wallet: wallet,
                            endpoints: desiredSnapshot.endpoints,
                            invoiceRevision: desiredSnapshot.invoiceRevision,
                            reconciliationRevision: pendingRevision,
                            publicAddress: desiredSnapshot.publicAddress,
                            session: session,
                            isSessionCurrent: isSessionCurrent
                        )
                    }
                }
            )
        }
    }

    @MainActor
    static func syncPublishedEndpoints(
        publish: Bool,
        isSessionCurrent: (@MainActor () -> Bool)? = nil,
        buildEndpoints: () async throws -> [Endpoint],
        syncApp: () async throws -> Void,
        applyEndpoints: ([Endpoint]) async throws -> Void,
        onPublished: () -> Void = {}
    ) async throws {
        try await ProfileOperationAdmission.shared.withOperation {
            if let isSessionCurrent, !isSessionCurrent() {
                throw PubkyServiceError.sessionNotActive
            }
            let desiredEndpoints: Result<[Endpoint], Error>
            do {
                desiredEndpoints = try await .success(publish ? buildEndpoints() : [])
            } catch {
                desiredEndpoints = .failure(error)
            }
            try await withEndpointLock(unlessSessionEnded: isSessionCurrent) {
                guard publish else {
                    var firstError: Error?
                    do {
                        try await applyEndpoints([])
                    } catch {
                        firstError = firstError ?? error
                    }
                    try ProfileOperationAdmission.shared.checkCurrent()
                    if let isSessionCurrent, !isSessionCurrent() {
                        throw PubkyServiceError.sessionNotActive
                    }
                    do {
                        try await syncApp()
                    } catch {
                        firstError = firstError ?? error
                    }
                    if let firstError {
                        throw firstError
                    }
                    return
                }

                // Persist retry work before a remote mutation can commit without an acknowledgement.
                setCleanupPending(true)
                try await syncApp()
                try ProfileOperationAdmission.shared.checkCurrent()
                if let isSessionCurrent, !isSessionCurrent() {
                    throw PubkyServiceError.sessionNotActive
                }
                // Keep the App Registry current even when wallet endpoints are unavailable.
                try await applyEndpoints(desiredEndpoints.get())
                try ProfileOperationAdmission.shared.checkCurrent()
                // A later writer must not begin before this publication's acknowledgement.
                onPublished()
            }
        }
    }

    @MainActor
    static func syncCurrentPublishedEndpoints(
        wallet: WalletViewModel,
        isSessionCurrent: (@MainActor () -> Bool)? = nil,
        syncApp: (() async throws -> Void)? = nil,
        applyEndpoints: (([Endpoint]) async throws -> Void)? = nil
    ) async throws {
        try await ProfileOperationAdmission.shared.withOperation {
            if let isSessionCurrent, !isSessionCurrent() {
                throw PubkyServiceError.sessionNotActive
            }
            let session = wallet.publicPaykitSession
            wallet.preparePendingPublicPaykitInvoiceRefresh()
            let pendingRevision = reconciliationRevision
            let (desiredEndpoints, invoiceRevision, publicAddress) = try await buildWalletEndpoints(
                wallet: wallet,
                session: session,
                refreshIfNeeded: false,
                requireEndpoint: false
            )
            let apply = applyEndpoints ?? { try await applyPublishedEndpointsLocked($0, isSessionCurrent: isSessionCurrent) }
            try await syncPublishedEndpoints(
                publish: true,
                isSessionCurrent: isSessionCurrent,
                buildEndpoints: { desiredEndpoints },
                syncApp: syncApp ?? { try await syncPaykitApp(isSessionCurrent: isSessionCurrent) },
                applyEndpoints: { endpoints in
                    markPublicationPending(wallet: wallet, session: session, isSessionCurrent: isSessionCurrent)
                    try await apply(endpoints)
                },
                onPublished: {
                    acknowledgePublishedEndpoints(
                        wallet: wallet,
                        endpoints: desiredEndpoints,
                        invoiceRevision: invoiceRevision,
                        reconciliationRevision: pendingRevision,
                        publicAddress: publicAddress,
                        session: session,
                        isSessionCurrent: isSessionCurrent
                    )
                }
            )
        }
    }

    @MainActor
    static func retryPendingEndpointReconciliation(
        wallet: WalletViewModel,
        isSessionCurrent: @escaping @MainActor () -> Bool,
        syncApp: (() async throws -> Void)? = nil,
        applyEndpoints: (([Endpoint]) async throws -> Void)? = nil
    ) async throws {
        try await ProfileOperationAdmission.shared.withOperation {
            guard isCleanupPending, !Task.isCancelled, isSessionCurrent() else { return }
            let mode = pendingReconciliationMode()
            let isCurrent = { @MainActor in
                !Task.isCancelled && isSessionCurrent() && pendingReconciliationMode() == mode
            }
            switch mode {
            case .publishEndpoints:
                try await syncCurrentPublishedEndpoints(
                    wallet: wallet, isSessionCurrent: isCurrent, syncApp: syncApp, applyEndpoints: applyEndpoints
                )
            case .removePublishedState:
                try await syncPublishedEndpoints(
                    wallet: wallet, publish: false, isSessionCurrent: isCurrent, syncApp: syncApp, applyEndpoints: applyEndpoints
                )
                guard isCurrent() else { return }
                setCleanupPending(false)
            }
        }
    }

    @MainActor
    private static func markPublicationPending(
        wallet: WalletViewModel,
        session: PubkyProfileManager.SignedInSession?,
        isSessionCurrent: (@MainActor () -> Bool)?
    ) {
        guard let isSessionCurrent, !Task.isCancelled, isSessionCurrent(),
              wallet.publicPaykitSession == session,
              pendingReconciliationMode() == .publishEndpoints
        else { return }
        setCleanupPending(true)
    }

    @MainActor
    private static func acknowledgePublishedEndpoints(
        wallet: WalletViewModel,
        endpoints: [Endpoint],
        invoiceRevision: UUID,
        reconciliationRevision: String?,
        publicAddress: PrivatePaykitAddressReservationStore.PublicAddressSnapshot?,
        session: PubkyProfileManager.SignedInSession?,
        isSessionCurrent: (@MainActor () -> Bool)?
    ) {
        // An older snapshot can finish after an invoice or address replacement.
        guard let isSessionCurrent, !Task.isCancelled, isSessionCurrent(),
              wallet.publicPaykitSession == session,
              pendingReconciliationMode() == .publishEndpoints
        else { return }
        let publishedCurrentInvoice = !isLightningPaymentOptionEnabled() ||
            (wallet.publicPaykitInvoiceRevision == invoiceRevision && wallet.publicPaykitBolt11 ==
                (endpoints.first { $0.methodId == .bitcoinLightningBolt11 }?.value ?? ""))
        let publishedUsdt = !isUsdtPaymentOptionEnabled() || endpoints.contains { $0.methodId == .usdtArbitrum }
        let acknowledge = { (hasCurrentAddress: Bool) in
            guard !Task.isCancelled, isSessionCurrent(), wallet.publicPaykitSession == session,
                  pendingReconciliationMode() == .publishEndpoints
            else { return }
            if hasCurrentAddress, publishedCurrentInvoice, publishedUsdt {
                acknowledgeReconciliation(revision: reconciliationRevision)
            } else {
                setCleanupPending(true)
            }
        }
        if !isOnchainPaymentOptionEnabled() {
            acknowledge(true)
        } else if let publicAddress, publicAddress.publicKey == session.flatMap({ PubkyPublicKeyFormat.normalized($0.publicKey) }),
                  endpoints.contains(where: { $0.value == publicAddress.address && $0.methodId.onchainNetwork != nil })
        {
            publicAddress.withCurrentReservation(acknowledge)
        } else {
            acknowledge(false)
        }
    }

    static func removePublishedEndpoints() async throws {
        try await applyPublishedEndpoints([])
    }

    static func syncPaykitApp(
        privateSharingEnabled: Bool? = nil,
        priority: PaykitSdkOperationLock.Priority = .ordered,
        isSessionCurrent: (@MainActor () -> Bool)? = nil,
        sdkService: PaykitSdkService = .shared
    ) async throws {
        try await sdkService.syncPaykitApp(
            privatePaymentsEnabled: privateSharingEnabled, priority: priority, isSessionCurrent: isSessionCurrent
        )
    }

    static func hasPayablePublicEndpoint(publicKey: String) async throws -> Bool {
        let endpoints = try await payablePublicEndpoints(publicKey: publicKey)
        return !endpoints.isEmpty
    }

    static func payablePublicEndpoints(publicKey: String) async throws -> [Endpoint] {
        let endpoints = try await fetchPublicEndpoints(publicKey: publicKey)
        return await payableEndpoints(from: endpoints)
    }

    static func payableEndpoints(from endpoints: [Endpoint]) async -> [Endpoint] {
        var payableEndpoints: [Endpoint] = []

        for endpoint in endpoints {
            if await isPayableEndpoint(endpoint) {
                payableEndpoints.append(endpoint)
            }
        }

        return payableEndpoints
    }

    static func beginPayment(
        to publicKey: String
    ) async throws -> PublicPaykitPaymentLaunchResult {
        let endpoints = try await fetchPublicEndpoints(publicKey: publicKey)
        let payableEndpoints = await payableEndpoints(from: endpoints)

        guard !payableEndpoints.isEmpty else {
            return endpoints.isEmpty ? .noEndpoint : .notOpened
        }

        return .opened(paymentRequest: paymentRequest(from: payableEndpoints), privatePaymentContext: nil, endpoints: payableEndpoints)
    }

    static func paymentRequest(from endpoints: [Endpoint]) -> String {
        guard let onchainEndpoint = MethodId.onchainPreferenceOrder.compactMap({ methodId in endpoints.first { $0.methodId == methodId } }).first,
              let bolt11Endpoint = endpoints.first(where: { $0.methodId == .bitcoinLightningBolt11 })
        else {
            return endpoints.first?.paymentRequest ?? ""
        }

        var allowedCharacters = CharacterSet.urlQueryAllowed
        allowedCharacters.remove(charactersIn: "?&=")
        let lightningPaymentRequest = bolt11Endpoint.paymentRequest
        let encodedLightning = lightningPaymentRequest.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? lightningPaymentRequest
        return "bitcoin:\(onchainEndpoint.paymentRequest)?lightning=\(encodedLightning)"
    }

    static func onchainMethodId(for address: String, network: LDKNode.Network = Env.network) -> MethodId {
        let normalizedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scriptType: OnchainScriptType = if normalizedAddress.hasPrefix("bc1p") || normalizedAddress.hasPrefix("tb1p") || normalizedAddress
            .hasPrefix("bcrt1p")
        {
            .p2tr
        } else if normalizedAddress.hasPrefix("bc1q") || normalizedAddress.hasPrefix("tb1q") || normalizedAddress.hasPrefix("bcrt1q") {
            .p2wpkh
        } else if normalizedAddress.hasPrefix("3") || normalizedAddress.hasPrefix("2") {
            .p2sh
        } else {
            .p2pkh
        }

        return MethodId.onchainMethodId(network: network, scriptType: scriptType)
    }

    static func isLightningPaymentOptionEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: lightningPaymentOptionEnabledKey) as? Bool ?? true
    }

    static func isOnchainPaymentOptionEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: onchainPaymentOptionEnabledKey) as? Bool ?? true
    }

    static func isUsdtPaymentOptionEnabled(defaults: UserDefaults = .standard) -> Bool {
        Env.isUsdtEnabled && UsdtPreference.isEnabled(defaults: defaults) && (defaults.object(forKey: usdtPaymentOptionEnabledKey) as? Bool ?? true)
    }

    static func hasLightningRouteHints(bolt11: String) -> Bool {
        guard let invoice = try? Bolt11Invoice.fromStr(invoiceStr: bolt11) else {
            return false
        }

        return invoice.routeHints().contains { !$0.isEmpty }
    }

    /// Runs `operation` under the lock that publishing and removing public endpoints share. Sign-out changes the current
    /// Pubky session before it removes endpoints under this lock, so checking `isSessionCurrent` once the lock is held
    /// stops a publish that would otherwise write endpoints back after that removal. A newer contact payments change
    /// likewise starts before it writes endpoints under this lock, so an older change's check stops its publish or removal.
    static func withEndpointLock<T>(
        unlessSessionEnded isSessionCurrent: (@MainActor () -> Bool)? = nil,
        _ operation: () async throws -> T
    ) async throws -> T {
        try await ProfileOperationAdmission.shared.withOperation {
            try await endpointLock.withLock {
                try ProfileOperationAdmission.shared.checkCurrent()
                if let isSessionCurrent, await !isSessionCurrent() {
                    throw PubkyServiceError.sessionNotActive
                }
                return try await operation()
            }
        }
    }

    private static func applyPublishedEndpoints(
        _ desiredEndpoints: [Endpoint],
        unlessSessionEnded isSessionCurrent: (@MainActor () -> Bool)? = nil,
        beforeApplying: () async throws -> Void = {}
    ) async throws {
        try await withEndpointLock(unlessSessionEnded: isSessionCurrent) {
            try await beforeApplying()
            try await applyPublishedEndpointsLocked(desiredEndpoints, isSessionCurrent: isSessionCurrent)
        }
    }

    private static func applyPublishedEndpointsLocked(
        _ desiredEndpoints: [Endpoint], isSessionCurrent: (@MainActor () -> Bool)? = nil
    ) async throws {
        let report = try await PaykitSdkService.shared.syncPublicEndpoints(desiredEndpoints, isSessionCurrent: isSessionCurrent)
        guard report.failed.isEmpty else {
            throw PublicPaykitError.publicationFailed
        }
    }

    @MainActor
    private static func buildWalletEndpoints(
        wallet: WalletViewModel,
        session: PubkyProfileManager.SignedInSession?,
        refreshIfNeeded: Bool,
        requireEndpoint: Bool
    ) async throws -> (endpoints: [Endpoint], invoiceRevision: UUID, publicAddress: PrivatePaykitAddressReservationStore.PublicAddressSnapshot?) {
        let includeOnchain = isOnchainPaymentOptionEnabled()
        let includeLightning = isLightningPaymentOptionEnabled()

        if refreshIfNeeded, includeOnchain || includeLightning {
            let isNodeReady = await wallet.waitForNodeToRun()
            let lifecycleState = wallet.nodeLifecycleState
            guard isNodeReady || lifecycleState == .running else {
                throw PublicPaykitError.walletNotReady
            }
        }

        guard wallet.publicPaykitSession == session else { throw PubkyServiceError.sessionNotActive }
        let publicEndpoints = try await wallet.refreshPublicPaykitEndpoints(
            forceRefreshBolt11: refreshIfNeeded && includeLightning,
            includeOnchain: includeOnchain,
            includeLightning: includeLightning
        )
        // Keep the invoice revision tied to this snapshot across USDT preparation.
        let invoiceRevision = wallet.publicPaykitInvoiceRevision
        var endpoints: [Endpoint] = []

        let onchainAddress = publicEndpoints.onchainAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if includeOnchain, !onchainAddress.isEmpty {
            try endpoints.append(
                Endpoint(
                    methodId: onchainMethodId(for: onchainAddress),
                    value: onchainAddress,
                    min: nil,
                    max: nil,
                    rawPayload: serializePayload(value: onchainAddress)
                )
            )
        }

        let bolt11 = publicEndpoints.bolt11.trimmingCharacters(in: .whitespacesAndNewlines)
        if includeLightning, !bolt11.isEmpty {
            try endpoints.append(
                Endpoint(
                    methodId: .bitcoinLightningBolt11,
                    value: bolt11,
                    min: nil,
                    max: nil,
                    rawPayload: serializePayload(value: bolt11)
                )
            )
        }

        if isUsdtPaymentOptionEnabled() {
            do {
                try await endpoints.append(wallet.usdtWallet.paymentEndpoint())
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                Logger.warn("Deferred USDT endpoint preparation", context: "PublicPaykitService")
            }
        }

        guard !endpoints.isEmpty || !requireEndpoint else {
            throw PublicPaykitError.noSupportedEndpoint
        }

        return (endpoints, invoiceRevision, publicEndpoints.onchainSnapshot)
    }

    private static func isPayableEndpoint(_ endpoint: Endpoint) async -> Bool {
        switch endpoint.methodId {
        case .usdtArbitrum:
            return Env.isUsdtEnabled && PaykitUsdt.address(from: endpoint.rawPayload) != nil
        case .bitcoinLightningBolt11:
            guard case let .lightning(invoice) = try? await decode(invoice: endpoint.paymentRequest), !invoice.isExpired else {
                return false
            }

            let invoiceNetwork = NetworkValidationHelper.convertNetworkType(invoice.networkType)
            return !NetworkValidationHelper.isNetworkMismatch(addressNetwork: invoiceNetwork, currentNetwork: Env.network)

        case .bitcoinLightningLnurl:
            guard case .lnurlPay = try? await decode(invoice: endpoint.paymentRequest) else {
                return false
            }

            return true

        case .bitcoinOnchainP2tr, .bitcoinOnchainP2wpkh, .bitcoinOnchainP2sh, .bitcoinOnchainP2pkh,
             .testnetOnchainP2tr, .testnetOnchainP2wpkh, .testnetOnchainP2sh, .testnetOnchainP2pkh,
             .signetOnchainP2tr, .signetOnchainP2wpkh, .signetOnchainP2sh, .signetOnchainP2pkh,
             .regtestOnchainP2tr, .regtestOnchainP2wpkh, .regtestOnchainP2sh, .regtestOnchainP2pkh:
            guard endpoint.methodId.onchainNetwork == Env.network,
                  case let .onChain(invoice) = try? await decode(invoice: endpoint.paymentRequest)
            else {
                return false
            }

            let addressValidation = try? validateBitcoinAddress(address: invoice.address)
            let addressNetwork = addressValidation.map { NetworkValidationHelper.convertNetworkType($0.network) }
            return !NetworkValidationHelper.isNetworkMismatch(addressNetwork: addressNetwork, currentNetwork: Env.network)
        }
    }
}
