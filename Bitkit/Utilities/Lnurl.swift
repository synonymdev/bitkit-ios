import BitkitCore
import Foundation

@MainActor
struct LnurlHelper {
    /// Fetches a Lightning invoice from an LNURL pay callback
    /// - Parameters:
    ///   - callbackUrl: The LNURL callback URL
    ///   - amount: The amount in satoshis to pay
    ///   - comment: Optional comment to include with the payment
    /// - Returns: The bolt11 invoice string
    /// - Throws: Network or parsing errors
    static func fetchLnurlInvoice(
        callbackUrl: String,
        amount: UInt64,
        comment: String? = nil
    ) async throws -> String {
        // Build the callback URL with amount parameter
        var urlComponents = URLComponents(string: callbackUrl)
        var queryItems = [
            URLQueryItem(name: "amount", value: String(amount * 1000)) // Convert to millisatoshis
        ]

        // Add comment if provided
        if let comment = comment, !comment.isEmpty {
            queryItems.append(URLQueryItem(name: "comment", value: comment))
        }

        urlComponents?.queryItems = queryItems

        guard let callbackURL = urlComponents?.url else {
            throw NSError(domain: "Payment", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid callback URL"])
        }

        Logger.debug("Making GET request to: \(callbackURL.absoluteString)")

        // Make the GET request
        let (data, response) = try await URLSession.shared.data(from: callbackURL)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "Payment", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }

        Logger.debug("LNURL callback response status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            throw NSError(
                domain: "Payment", code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP request failed with status \(httpResponse.statusCode)"])
        }

        // Parse the response
        guard let responseString = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Payment", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response data"])
        }

        Logger.debug("LNURL callback response: \(responseString)")

        // Parse JSON response to get the invoice
        guard let jsonData = responseString.data(using: .utf8) else {
            throw NSError(domain: "Payment", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert response to data"])
        }

        struct LnurlPayResponse: Codable {
            let pr: String
            let routes: [String]
        }

        let lnurlResponse = try JSONDecoder().decode(LnurlPayResponse.self, from: jsonData)
        let bolt11Invoice = lnurlResponse.pr

        Logger.debug("Extracted bolt11 invoice: \(bolt11Invoice)")

        return bolt11Invoice
    }

    /// Handles LNURL Withdraw Requests
    /// - Parameters:
    ///   - amount: The amount in satoshis to withdraw
    ///   - params: The LNURL withdraw parameters
    ///   - wallet: The wallet service to create invoices
    /// - Returns: Success or error message
    /// - Throws: Network or parsing errors
    static func handleLnurlWithdraw(
        amount: UInt64,
        params: LnurlWithdrawData,
        wallet: WalletViewModel
    ) async throws {
        // Create a Lightning invoice for the withdraw
        let invoice = try await wallet.createInvoice(
            amountSats: amount,
            note: params.defaultDescription,
            expirySecs: 3600
        )

        Logger.debug("Created withdraw invoice: \(invoice)")

        // Build the callback URL with the payment request
        var urlComponents = URLComponents(string: params.callback)
        urlComponents?.queryItems = [
            URLQueryItem(name: "k1", value: params.k1),
            URLQueryItem(name: "pr", value: invoice),
        ]

        guard let callbackURL = urlComponents?.url else {
            throw NSError(domain: "Payment", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid callback URL"])
        }

        Logger.debug("Making withdraw callback request to: \(callbackURL.absoluteString)")

        // Make the callback request
        let (data, response) = try await URLSession.shared.data(from: callbackURL)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "Payment", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }

        Logger.debug("LNURL withdraw callback response status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            throw NSError(
                domain: "Payment", code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP request failed with status \(httpResponse.statusCode)"])
        }

        // Parse the response
        guard let responseString = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Payment", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response data"])
        }

        Logger.debug("LNURL withdraw callback response: \(responseString)")

        // Parse JSON response
        guard let jsonData = responseString.data(using: .utf8) else {
            throw NSError(domain: "Payment", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert response to data"])
        }

        struct LnurlWithdrawResponse: Codable {
            let status: String
            let reason: String?
        }

        let withdrawResponse = try JSONDecoder().decode(LnurlWithdrawResponse.self, from: jsonData)

        if withdrawResponse.status == "ERROR" {
            let errorMessage = withdrawResponse.reason ?? "Unknown error"
            Logger.error("LNURL withdraw failed: \(errorMessage)")
            throw NSError(domain: "Payment", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }

        Logger.debug("LNURL withdraw successful")
    }
}
