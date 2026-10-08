import BitkitCore
import Foundation

enum PaykitUsdt {
    static let chainId = "42161"
    static let token = "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9"

    static func address(from payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["chain_id"] as? String == chainId,
              (object["token"] as? String)?.lowercased() == token,
              let value = object["value"] as? String,
              value.count == 42,
              let request = try? usdtParsePaymentRequest(value: value),
              request.chainId == nil, request.amount == nil
        else { return nil }
        return request.recipient
    }

    static func endpoint(address: String) throws -> PublicPaykitService.Endpoint {
        let data = try JSONSerialization.data(withJSONObject: ["value": address, "chain_id": chainId, "token": token])
        let payload = String(decoding: data, as: UTF8.self)
        guard let address = self.address(from: payload) else { throw PublicPaykitError.invalidPayload }
        return PublicPaykitService.Endpoint(methodId: .usdtArbitrum, value: address, min: nil, max: nil, rawPayload: payload)
    }

    static func paymentURI(address: String) -> String {
        "ethereum:\(token)@\(chainId)/transfer?address=\(address)"
    }
}
