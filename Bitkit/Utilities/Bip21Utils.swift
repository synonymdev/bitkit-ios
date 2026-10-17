import Foundation

/// Utility methods for BIP21 URI handling
enum Bip21Utils {
    static func hardwareInvoice(address: String, amountSats: UInt64, message: String) -> String {
        var components = URLComponents()
        components.scheme = "bitcoin"
        components.path = address

        var queryItems: [URLQueryItem] = []
        if amountSats > 0 {
            queryItems.append(
                URLQueryItem(
                    name: "amount",
                    value: WalletViewModel.formatBitcoinAmount(sats: amountSats)
                )
            )
        }
        if !message.isEmpty {
            queryItems.append(URLQueryItem(name: "message", value: message))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.string ?? "bitcoin:\(address)"
    }
}
