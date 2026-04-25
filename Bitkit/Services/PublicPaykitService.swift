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
    case opened
    case noEndpoint
    case notOpened
}

enum PublicPaykitService {
    enum MethodId: String, Hashable {
        case bitcoinLightningBolt11 = "btc-lightning-bolt11"
        case bitcoinLightningLnurl = "btc-lightning-lnurl-pay"
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
            await removePublishedEndpoints()
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

    static func removePublishedEndpoints() async {
        for methodId in MethodId.publishableMethodIds {
            try? await PubkyService.removePaymentEndpoint(methodId: methodId.rawValue)
        }
    }

    @MainActor
    static func beginPayment(
        to publicKey: String,
        app: AppViewModel,
        currency: CurrencyViewModel,
        settings: SettingsViewModel,
        sheets: SheetViewModel
    ) async throws -> PublicPaykitPaymentLaunchResult {
        let endpoints = try await fetchPublicEndpoints(publicKey: publicKey)

        guard let preferredEndpoint = await preferredPayableEndpoint(from: endpoints) else {
            return endpoints.isEmpty ? .noEndpoint : .notOpened
        }

        try await app.handleScannedData(preferredEndpoint.paymentRequest)

        guard PaymentNavigationHelper.appropriateSendRoute(app: app, currency: currency, settings: settings) != nil else {
            return .notOpened
        }

        app.contactPaymentContext = ContactPaymentContext(publicKey: publicKey)
        PaymentNavigationHelper.openPaymentSheet(
            app: app,
            currency: currency,
            settings: settings,
            sheetViewModel: sheets
        )

        return .opened
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
        let desiredMethodIds = Set(desiredEndpoints.map(\.methodId))

        for endpoint in desiredEndpoints {
            try await PubkyService.setPaymentEndpoint(
                methodId: endpoint.methodId.rawValue,
                endpointData: endpoint.rawPayload
            )
        }

        for methodId in MethodId.publishableMethodIds where !desiredMethodIds.contains(methodId) {
            try? await PubkyService.removePaymentEndpoint(methodId: methodId.rawValue)
        }
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

    private static func preferredPayableEndpoint(from endpoints: [Endpoint]) async -> Endpoint? {
        for endpoint in endpoints {
            if await isPayableEndpoint(endpoint) {
                return endpoint
            }
        }

        return nil
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
