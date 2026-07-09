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

enum PublicPaykitPaymentLaunchResult {
    case opened(paymentRequest: String)
    case noEndpoint
    case notOpened

    var contactPaymentFailureMessageKey: String? {
        switch self {
        case .opened:
            nil
        case .noEndpoint:
            "slashtags__error_pay_empty_msg"
        case .notOpened:
            "slashtags__error_pay_not_opened_msg"
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
    static let cleanupPendingKey = "publicPaykitCleanupPending"

    static func setCleanupPending(_ isPending: Bool) {
        UserDefaults.standard.set(isPending, forKey: cleanupPendingKey)
    }

    static var isCleanupPending: Bool {
        UserDefaults.standard.bool(forKey: cleanupPendingKey)
    }

    enum MethodId: String, Hashable, CaseIterable {
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
        ] + onchainPreferenceOrder

        static let publishableMethodIds: [MethodId] = [
            .bitcoinLightningBolt11,
        ] + onchainPreferenceOrder

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
            case .bitcoinLightningBolt11, .bitcoinLightningLnurl:
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

        var paymentRequest: String {
            value
        }
    }

    static func fetchPublicEndpoints(publicKey: String) async throws -> [Endpoint] {
        let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) ?? publicKey
        let resolution = try await PaykitSdkService.shared.resolvePublicContactPayment(counterparty: normalizedKey)
        var endpointsByMethodId: [MethodId: Endpoint] = [:]

        for resolvedEndpoint in resolution.payableEndpoints {
            guard let endpoint = parseEndpoint(identifier: resolvedEndpoint.identifier, payload: resolvedEndpoint.target.payload) else {
                continue
            }

            endpointsByMethodId[endpoint.methodId] = endpoint
        }

        return MethodId.payablePreferenceOrder.compactMap { endpointsByMethodId[$0] }
    }

    static func parseEndpoint(methodId rawMethodId: String, endpointData: String) -> Endpoint? {
        guard let methodId = MethodId(rawValue: rawMethodId) else {
            return nil
        }

        guard let payload = parsePayload(endpointData) else {
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

    static func parseEndpoint(candidate: PaymentEndpointCandidate) -> Endpoint? {
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
    static func syncPublishedEndpoints(wallet: WalletViewModel, publish: Bool) async throws {
        guard publish else {
            try await removePublishedEndpoints()
            return
        }

        let desiredEndpoints = try await buildWalletEndpoints(wallet: wallet, refreshIfNeeded: true, requireEndpoint: true)
        try await applyPublishedEndpoints(desiredEndpoints)
    }

    @MainActor
    static func syncCurrentPublishedEndpoints(wallet: WalletViewModel) async throws {
        let desiredEndpoints = try await buildWalletEndpoints(wallet: wallet, refreshIfNeeded: false, requireEndpoint: false)
        try await applyPublishedEndpoints(desiredEndpoints)
    }

    static func removePublishedEndpoints() async throws {
        try await applyPublishedEndpoints([])
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

        return .opened(paymentRequest: paymentRequest(from: payableEndpoints))
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

    static func hasLightningRouteHints(bolt11: String) -> Bool {
        guard let invoice = try? Bolt11Invoice.fromStr(invoiceStr: bolt11) else {
            return false
        }

        return invoice.routeHints().contains { !$0.isEmpty }
    }

    private struct ParsedPayload {
        let value: String
        let min: String?
        let max: String?
    }

    private static func parsePayload(_ endpointData: String) -> ParsedPayload? {
        let trimmedPayload = endpointData.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPayload.isEmpty else {
            return nil
        }

        if let data = trimmedPayload.data(using: .utf8),
           let payloadObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = (payloadObject["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty
        {
            return ParsedPayload(
                value: value,
                min: payloadObject["min"] as? String,
                max: payloadObject["max"] as? String
            )
        }

        return nil
    }

    private static func applyPublishedEndpoints(_ desiredEndpoints: [Endpoint]) async throws {
        try await endpointLock.withLock {
            let report = try await PaykitSdkService.shared.syncPublicEndpoints(desiredEndpoints)
            guard report.failed.isEmpty else {
                throw PublicPaykitError.publicationFailed
            }
        }
    }

    @MainActor
    private static func buildWalletEndpoints(wallet: WalletViewModel, refreshIfNeeded: Bool, requireEndpoint: Bool) async throws -> [Endpoint] {
        let includeOnchain = isOnchainPaymentOptionEnabled()
        let includeLightning = isLightningPaymentOptionEnabled()

        if refreshIfNeeded {
            let isNodeReady = await wallet.waitForNodeToRun()
            let lifecycleState = wallet.nodeLifecycleState
            guard isNodeReady || lifecycleState == .running else {
                throw PublicPaykitError.walletNotReady
            }

            _ = try await wallet.refreshPublicPaykitEndpoints(
                forceRefreshBolt11: includeLightning,
                includeOnchain: includeOnchain,
                includeLightning: includeLightning
            )
        }

        let publicEndpoints = try await wallet.refreshPublicPaykitEndpoints(
            forceRefreshBolt11: false,
            includeOnchain: includeOnchain,
            includeLightning: includeLightning
        )
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

        guard !endpoints.isEmpty || !requireEndpoint else {
            throw PublicPaykitError.noSupportedEndpoint
        }

        return endpoints
    }

    private static func isPayableEndpoint(_ endpoint: Endpoint) async -> Bool {
        switch endpoint.methodId {
        case .bitcoinLightningBolt11:
            guard case let .lightning(invoice) = try? await decode(invoice: endpoint.paymentRequest) else {
                return false
            }

            guard !invoice.isExpired else {
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
            guard endpoint.methodId.onchainNetwork == Env.network else {
                return false
            }

            guard case let .onChain(invoice) = try? await decode(invoice: endpoint.paymentRequest) else {
                return false
            }

            let addressValidation = try? validateBitcoinAddress(address: invoice.address)
            let addressNetwork = addressValidation.map { NetworkValidationHelper.convertNetworkType($0.network) }
            return !NetworkValidationHelper.isNetworkMismatch(addressNetwork: addressNetwork, currentNetwork: Env.network)
        }
    }
}
