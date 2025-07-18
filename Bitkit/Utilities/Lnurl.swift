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

private struct ChannelInfoResponse: Codable {
    let uri: String
    let tag: String
    let callback: String
    let k1: String
}

// MARK: - HTTP Helper

extension LnurlHelper {
    /// Makes an HTTP GET request and returns the response data
    /// - Parameter url: The URL to request
    /// - Returns: The response data as a string
    /// - Throws: Network or parsing errors
    fileprivate static func makeHttpGetRequest(url: URL) async throws -> String {
        Logger.debug("Making GET request to: \(url.absoluteString)")

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "LNURL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }

        Logger.debug("HTTP response status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            throw NSError(
                domain: "LNURL", code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP request failed with status \(httpResponse.statusCode)"])
        }

        guard let responseString = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "LNURL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response data"])
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
    fileprivate static func parseJsonResponse<T: Codable>(_ responseString: String, as responseType: T.Type) throws -> T {
        guard let jsonData = responseString.data(using: .utf8) else {
            throw NSError(domain: "LNURL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert response to data"])
        }

        return try JSONDecoder().decode(responseType, from: jsonData)
    }

    /// Builds a URL with query parameters
    /// - Parameters:
    ///   - baseUrl: The base URL string
    ///   - queryItems: The query parameters to add
    /// - Returns: The constructed URL
    /// - Throws: URL construction errors
    fileprivate static func buildUrl(baseUrl: String, queryItems: [URLQueryItem]) throws -> URL {
        var urlComponents = URLComponents(string: baseUrl)
        urlComponents?.queryItems = queryItems

        guard let url = urlComponents?.url else {
            throw NSError(domain: "LNURL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid callback URL"])
        }

        return url
    }

    /// Handles LNURL error responses
    /// - Parameter response: The response containing status and optional reason
    /// - Throws: Error if status is "ERROR"
    fileprivate static func handleLnurlError<T>(_ response: T) throws where T: Codable {
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
            URLQueryItem(name: "amount", value: String(amount * 1000)) // Convert to millisatoshis
        ]

        // Add comment if provided
        if let comment = comment, !comment.isEmpty {
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
        let queryItems = [
            URLQueryItem(name: "k1", value: params.k1),
            URLQueryItem(name: "remoteid", value: nodeId),
            URLQueryItem(name: "private", value: "1"), // Private channel
        ]

        let callbackURL = try buildUrl(baseUrl: params.callback, queryItems: queryItems)
        let responseString = try await makeHttpGetRequest(url: callbackURL)
        let channelResponse = try parseJsonResponse(responseString, as: LnurlChannelResponse.self)

        try handleLnurlError(channelResponse)
        Logger.debug("LNURL channel request successful")
    }

    /// Fetches LNURL channel information from the provided URL
    /// - Parameter url: The LNURL channel URL to fetch
    /// - Returns: The channel information including the node URI
    /// - Throws: Network or parsing errors
    static func fetchLnurlChannelInfo(url: String) async throws -> LnurlChannelData {
        Logger.debug("Fetching LNURL channel info from: \(url)")

        guard let channelUrl = URL(string: url) else {
            throw NSError(domain: "LNURL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid LNURL channel URL"])
        }

        let responseString = try await makeHttpGetRequest(url: channelUrl)
        let channelResponse = try parseJsonResponse(responseString, as: ChannelInfoResponse.self)

        let channelInfo = LnurlChannelData(
            uri: channelResponse.uri,
            callback: channelResponse.callback,
            k1: channelResponse.k1,
            tag: channelResponse.tag
        )

        Logger.debug("Parsed channel info - URI: \(channelInfo.uri), Tag: \(channelInfo.tag)")
        return channelInfo
    }
}
