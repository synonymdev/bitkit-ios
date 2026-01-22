import BitkitCore
import Foundation

// MARK: - Response Models

private struct LnurlPayResponse: Codable {
    let pr: String
    let routes: [String]
}

private struct LnurlWithdrawResponse: Codable {
    let status: String
    let reason: String?
}

private struct LnurlChannelResponse: Codable {
    let status: String
    let reason: String?
}

// MARK: - HTTP Helper

private extension LnurlHelper {
    /// Makes an HTTP GET request and returns the response data
    /// - Parameter url: The URL to request
    /// - Returns: The response data as a string
    /// - Throws: Network or parsing errors
    static func makeHttpGetRequest(url: URL) async throws -> String {
        Logger.debug("Making GET request to: \(url.absoluteString)")

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "LNURL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }

        Logger.debug("HTTP response status: \(httpResponse.statusCode)")

        guard let responseString = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "LNURL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response data"])
        }

        guard httpResponse.statusCode == 200 else {
            Logger.error("HTTP request failed with status \(httpResponse.statusCode), response: \(responseString)")
            throw NSError(
                domain: "LNURL", code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP request failed with status \(httpResponse.statusCode)"]
            )
        }

        Logger.debug("HTTP response: \(responseString)")
        return responseString
    }

    /// Parses JSON response and handles common error patterns
    /// - Parameters:
    ///   - responseString: The JSON response string
    ///   - responseType: The type to decode to
    /// - Returns: The decoded response
    /// - Throws: Parsing or business logic errors
    static func parseJsonResponse<T: Codable>(_ responseString: String, as responseType: T.Type) throws -> T {
        guard let jsonData = responseString.data(using: .utf8) else {
            throw NSError(domain: "LNURL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert response to data"])
        }

        return try JSONDecoder().decode(responseType, from: jsonData)
    }

    /// Builds a URL with query parameters
    /// - Parameters:
    ///   - baseUrl: The base URL string
    ///   - queryItems: The query parameters to add/override
    /// - Returns: The constructed URL
    /// - Throws: URL construction errors
    static func buildUrl(baseUrl: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var urlComponents = URLComponents(string: baseUrl) else {
            throw NSError(domain: "LNURL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid callback URL"])
        }

        // Get existing query items from the base URL
        var existingItems = urlComponents.queryItems ?? []

        // Remove any existing items that will be overridden by the new ones
        let newItemKeys = Set(queryItems.map(\.name))
        existingItems.removeAll { newItemKeys.contains($0.name) }

        // Append new query items
        existingItems.append(contentsOf: queryItems)
        urlComponents.queryItems = existingItems.isEmpty ? nil : existingItems

        guard let url = urlComponents.url else {
            throw NSError(domain: "LNURL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid callback URL"])
        }

        return url
    }

    /// Handles LNURL error responses
    /// - Parameter response: The response containing status and optional reason
    /// - Throws: Error if status is "ERROR"
    static func handleLnurlError(_ response: some Codable) throws {
        // Check if the response has a status field that indicates an error
        if let errorResponse = response as? LnurlWithdrawResponse,
           errorResponse.status == "ERROR"
        {
            let errorMessage = errorResponse.reason ?? "Unknown error"
            Logger.error("LNURL request failed: \(errorMessage)")
            throw NSError(domain: "LNURL", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }

        if let errorResponse = response as? LnurlChannelResponse,
           errorResponse.status == "ERROR"
        {
            let errorMessage = errorResponse.reason ?? "Unknown error"
            Logger.error("LNURL request failed: \(errorMessage)")
            throw NSError(domain: "LNURL", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
    }
}

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
        var queryItems = [
            URLQueryItem(name: "amount", value: String(amount * 1000)), // Convert to millisatoshis
        ]

        // Add comment if provided
        if let comment, !comment.isEmpty {
            queryItems.append(URLQueryItem(name: "comment", value: comment))
        }

        let callbackURL = try buildUrl(baseUrl: callbackUrl, queryItems: queryItems)
        let responseString = try await makeHttpGetRequest(url: callbackURL)
        let lnurlResponse = try parseJsonResponse(responseString, as: LnurlPayResponse.self)

        Logger.debug("Extracted bolt11 invoice: \(lnurlResponse.pr)")
        return lnurlResponse.pr
    }

    /// Handles LNURL Withdraw Requests
    /// - Parameters:
    ///   - params: The LNURL withdraw parameters
    ///   - invoice: The Lightning invoice to withdraw to
    /// - Throws: Network or parsing errors
    static func handleLnurlWithdraw(
        params: LnurlWithdrawData,
        invoice: String
    ) async throws {
        let queryItems = [
            URLQueryItem(name: "k1", value: params.k1),
            URLQueryItem(name: "pr", value: invoice),
        ]

        let callbackURL = try buildUrl(baseUrl: params.callback, queryItems: queryItems)
        let responseString = try await makeHttpGetRequest(url: callbackURL)
        let withdrawResponse = try parseJsonResponse(responseString, as: LnurlWithdrawResponse.self)

        try handleLnurlError(withdrawResponse)
        Logger.debug("LNURL withdraw successful")
    }

    /// Handles LNURL Channel Requests
    /// - Parameters:
    ///   - params: The LNURL channel parameters
    ///   - nodeId: The node ID to send with the request
    /// - Throws: Network or parsing errors
    static func handleLnurlChannel(
        params: LnurlChannelData,
        nodeId: String
    ) async throws {
        let callbackUrlString = try createChannelRequestUrl(
            k1: params.k1,
            callback: params.callback,
            localNodeId: nodeId,
            isPrivate: true,
            cancel: false
        )

        guard let callbackURL = URL(string: callbackUrlString) else {
            throw NSError(domain: "LNURL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid callback URL"])
        }

        let responseString = try await makeHttpGetRequest(url: callbackURL)
        let channelResponse = try parseJsonResponse(responseString, as: LnurlChannelResponse.self)

        try handleLnurlError(channelResponse)
        Logger.debug("LNURL channel request successful")
    }
}
