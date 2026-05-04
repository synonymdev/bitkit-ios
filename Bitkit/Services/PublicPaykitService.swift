import BitkitCore
import Foundation
import LDKNode

enum PublicPaykitError: LocalizedError {
    case noSupportedEndpoint
    case walletNotReady
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .noSupportedEndpoint:
            return "No supported public payment endpoint is available."
        case .walletNotReady:
            return "Bitkit could not prepare a public payment endpoint because the wallet is not ready."
        case .invalidPayload:
            return "The public payment endpoint payload is invalid."
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

enum PublicPaykitService {
    enum MethodId: String, Hashable {
        case bitcoinLightningBolt11 = "btc-lightning-bolt11"
        case bitcoinLightningLnurl = "btc-lightning-lnurl"
        case bitcoinOnchainP2tr = "btc-bitcoin-p2tr"
        case bitcoinOnchainP2wpkh = "btc-bitcoin-p2wpkh"
        case bitcoinOnchainP2sh = "btc-bitcoin-p2sh"
        case bitcoinOnchainP2pkh = "btc-bitcoin-p2pkh"

        static let payablePreferenceOrder: [MethodId] = [
            .bitcoinLightningBolt11,
            .bitcoinLightningLnurl,
            .bitcoinOnchainP2tr,
            .bitcoinOnchainP2wpkh,
            .bitcoinOnchainP2sh,
            .bitcoinOnchainP2pkh,
        ]

        static let publishableMethodIds: [MethodId] = [
            .bitcoinLightningBolt11,
            .bitcoinOnchainP2tr,
            .bitcoinOnchainP2wpkh,
            .bitcoinOnchainP2sh,
            .bitcoinOnchainP2pkh,
        ]

        static let onchainPreferenceOrder: [MethodId] = [
            .bitcoinOnchainP2tr,
            .bitcoinOnchainP2wpkh,
            .bitcoinOnchainP2sh,
            .bitcoinOnchainP2pkh,
        ]
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

    struct EndpointSyncPlan: Equatable {
        let endpointsToSet: [Endpoint]
        let methodIdsToRemove: [MethodId]
    }

    static func fetchPublicEndpoints(publicKey: String) async throws -> [Endpoint] {
        let paymentEntries = try await PubkyService.getPaymentList(publicKey: publicKey)
        var endpointsByMethodId: [MethodId: Endpoint] = [:]

        for entry in paymentEntries {
            guard let endpoint = parseEndpoint(methodId: entry.methodId, endpointData: entry.endpointData) else {
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

        let desiredEndpoints = try await buildWalletEndpoints(wallet: wallet, refreshIfNeeded: true)
        try await applyPublishedEndpoints(desiredEndpoints)
    }

    @MainActor
    static func syncCurrentPublishedEndpoints(wallet: WalletViewModel) async throws {
        let desiredEndpoints = try await buildWalletEndpoints(wallet: wallet, refreshIfNeeded: false)
        try await applyPublishedEndpoints(desiredEndpoints)
    }

    static func removePublishedEndpoints() async throws {
        let existingMethodIds = try await currentPublishedMethodIds()

        for methodId in methodIdsToRemoveWhenUnpublishing(existingMethodIds: existingMethodIds) {
            try await PubkyService.removePaymentEndpoint(methodId: methodId.rawValue)
        }
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

    static func onchainMethodId(for address: String) -> MethodId {
        let normalizedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalizedAddress.hasPrefix("bc1p") || normalizedAddress.hasPrefix("tb1p") || normalizedAddress.hasPrefix("bcrt1p") {
            return .bitcoinOnchainP2tr
        }

        if normalizedAddress.hasPrefix("bc1q") || normalizedAddress.hasPrefix("tb1q") || normalizedAddress.hasPrefix("bcrt1q") {
            return .bitcoinOnchainP2wpkh
        }

        if normalizedAddress.hasPrefix("3") || normalizedAddress.hasPrefix("2") {
            return .bitcoinOnchainP2sh
        }

        return .bitcoinOnchainP2pkh
    }

    static func methodIdsToRemoveWhenUnpublishing(existingMethodIds: Set<MethodId>) -> [MethodId] {
        MethodId.publishableMethodIds.filter { existingMethodIds.contains($0) }
    }

    static func publishedEndpointSyncPlan(existingEndpoints: [MethodId: String], desiredEndpoints: [Endpoint]) -> EndpointSyncPlan {
        let desiredMethodIds = Set(desiredEndpoints.map(\.methodId))
        return EndpointSyncPlan(
            endpointsToSet: desiredEndpoints.filter { existingEndpoints[$0.methodId] != $0.rawPayload },
            methodIdsToRemove: MethodId.publishableMethodIds.filter { existingEndpoints[$0] != nil && !desiredMethodIds.contains($0) }
        )
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
        let existingEndpoints = try await currentPublishedEndpoints()
        let plan = publishedEndpointSyncPlan(existingEndpoints: existingEndpoints, desiredEndpoints: desiredEndpoints)

        for endpoint in plan.endpointsToSet {
            try await PubkyService.setPaymentEndpoint(
                methodId: endpoint.methodId.rawValue,
                endpointData: endpoint.rawPayload
            )
        }

        for methodId in plan.methodIdsToRemove {
            try await PubkyService.removePaymentEndpoint(methodId: methodId.rawValue)
        }
    }

    private static func currentPublishedMethodIds() async throws -> Set<MethodId> {
        Set((try await currentPublishedEndpoints()).keys)
    }

    private static func currentPublishedEndpoints() async throws -> [MethodId: String] {
        guard let publicKey = await PubkyService.currentPublicKey() else {
            throw PubkyServiceError.sessionNotActive
        }

        let paymentEntries = try await PubkyService.getPaymentList(publicKey: publicKey)
        var endpoints: [MethodId: String] = [:]
        for entry in paymentEntries {
            guard let methodId = MethodId(rawValue: entry.methodId) else {
                continue
            }

            endpoints[methodId] = entry.endpointData
        }

        return endpoints
    }

    @MainActor
    private static func buildWalletEndpoints(wallet: WalletViewModel, refreshIfNeeded: Bool) async throws -> [Endpoint] {
        if refreshIfNeeded {
            let isNodeReady = await wallet.waitForNodeToRun()
            let lifecycleState = wallet.nodeLifecycleState
            guard isNodeReady || lifecycleState == .running else {
                throw PublicPaykitError.walletNotReady
            }

            try await wallet.refreshBip21(forceRefreshBolt11: true)
        }

        var endpoints: [Endpoint] = []

        let onchainAddress = wallet.onchainAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !onchainAddress.isEmpty {
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

        let bolt11 = wallet.bolt11.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bolt11.isEmpty {
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

        guard !endpoints.isEmpty else {
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

        case .bitcoinOnchainP2tr, .bitcoinOnchainP2wpkh, .bitcoinOnchainP2sh, .bitcoinOnchainP2pkh:
            guard case let .onChain(invoice) = try? await decode(invoice: endpoint.paymentRequest) else {
                return false
            }

            let addressValidation = try? validateBitcoinAddress(address: invoice.address)
            let addressNetwork = addressValidation.map { NetworkValidationHelper.convertNetworkType($0.network) }
            return !NetworkValidationHelper.isNetworkMismatch(addressNetwork: addressNetwork, currentNetwork: Env.network)
        }
    }
}
