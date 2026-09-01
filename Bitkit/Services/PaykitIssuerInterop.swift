import Foundation
import LDKNode

enum PaykitIssuerInterop {
    static let bitcoinAsset = "btc"

    struct EndpointPayload: Equatable {
        let value: String
        let min: String?
        let max: String?
    }

    static func supportedEndpointIdentifiers(_ identifiers: [String], network: LDKNode.Network) -> [String] {
        var seen = Set<String>()
        return identifiers.filter { identifier in
            guard seen.insert(identifier).inserted,
                  let methodId = PublicPaykitService.MethodId(rawValue: identifier)
            else { return false }

            if let onchainNetwork = methodId.onchainNetwork {
                return onchainNetwork == network
            }

            return methodId == .bitcoinLightningBolt11 || methodId == .bitcoinLightningLnurl
        }
    }

    static func parseEndpointPayload(_ endpointData: String) -> EndpointPayload? {
        let trimmedPayload = endpointData.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPayload.isEmpty,
              let data = trimmedPayload.data(using: .utf8),
              let payloadObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = (payloadObject["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }

        return EndpointPayload(
            value: value,
            min: payloadObject["min"] as? String,
            max: payloadObject["max"] as? String
        )
    }
}
