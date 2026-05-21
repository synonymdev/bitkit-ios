import BitkitCore
import Foundation

struct SamRockSetupRequest: Equatable {
    enum PaymentMethod: String {
        case all
        case btc
        case btcOnchain = "btc-chain"
        case liquid = "lbtc"
        case liquidOnchain = "liquid-chain"
        case lightning = "btcln"
        case lightningOnchain = "btc-ln"
    }

    let url: URL
    let postURL: URL
    let storeId: String
    let otp: String
    let requestedMethods: Set<PaymentMethod>
    let hasUnknownSetupMethods: Bool

    var hostDisplayName: String {
        guard let host = url.host else { return t("btcpay__unknown_host") }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }

    var requestsBitcoinOnchain: Bool {
        requestedMethods.contains(.all) || requestedMethods.contains(.btc) || requestedMethods.contains(.btcOnchain)
    }

    var requestsUnsupportedMethods: Bool {
        hasUnknownSetupMethods || requestedMethods.contains { method in
            switch method {
            case .all, .liquid, .liquidOnchain, .lightning, .lightningOnchain:
                return true
            case .btc, .btcOnchain:
                return false
            }
        }
    }

    static func parse(_ rawValue: String) -> SamRockSetupRequest? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let url = components.url,
              allowsSetupURLScheme(components),
              components.user == nil,
              components.password == nil,
              let queryItems = components.queryItems
        else {
            return nil
        }

        let pathComponents = url.path
            .split(separator: "/")
            .map(String.init)

        guard pathComponents.count == 4,
              pathComponents[0] == "plugins",
              pathComponents[2].caseInsensitiveCompare("samrock") == .orderedSame,
              pathComponents[3].caseInsensitiveCompare("protocol") == .orderedSame
        else {
            return nil
        }

        guard let otp = queryItems.first(where: { $0.name.caseInsensitiveCompare("otp") == .orderedSame })?.value,
              !otp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let setupValue = queryItems.first(where: { $0.name.caseInsensitiveCompare("setup") == .orderedSame })?.value
        let parsedMethods = parseMethods(setupValue)

        var postQueryItems = [URLQueryItem]()
        if let setupValue {
            postQueryItems.append(URLQueryItem(name: "setup", value: setupValue))
        }
        postQueryItems.append(URLQueryItem(name: "otp", value: otp))

        var postComponents = components
        postComponents.queryItems = postQueryItems

        guard let postURL = postComponents.url else { return nil }

        return SamRockSetupRequest(
            url: url,
            postURL: postURL,
            storeId: pathComponents[1].removingPercentEncoding ?? pathComponents[1],
            otp: otp,
            requestedMethods: parsedMethods.methods,
            hasUnknownSetupMethods: parsedMethods.hasUnknownMethods
        )
    }

    static func sanitizedDescription(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if var components = URLComponents(string: trimmed),
           components.host != nil,
           isProtocolPath(components)
        {
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            return components.string
        }

        let withoutQuery = trimmed.prefix { character in
            character != "?" && character != "#"
        }
        let normalized = withoutQuery.lowercased()
        guard normalized.contains("/plugins/"),
              normalized.contains("/samrock/protocol")
        else {
            return nil
        }

        let fallback = String(withoutQuery)
        if var components = URLComponents(string: fallback),
           components.host != nil
        {
            components.user = nil
            components.password = nil
            return components.string ?? fallback.strippingUserInfoFromAuthority()
        }

        return fallback.strippingUserInfoFromAuthority()
    }

    static func isProtocolURL(_ rawValue: String) -> Bool {
        sanitizedDescription(rawValue) != nil
    }

    static func isPublicHTTPProtocolURL(_ rawValue: String) -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased(),
              isProtocolPath(components)
        else {
            return false
        }

        return !isLocalOrPrivateHost(host)
    }

    private static func parseMethods(_ value: String?) -> (methods: Set<PaymentMethod>, hasUnknownMethods: Bool) {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ([.all], false)
        }

        var methods = Set<PaymentMethod>()
        var hasUnknownMethods = false

        for rawMethod in value.split(separator: ",") {
            let normalized = rawMethod.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { continue }

            if let method = PaymentMethod(rawValue: normalized) {
                methods.insert(method)
            } else {
                hasUnknownMethods = true
            }
        }

        return (methods, hasUnknownMethods)
    }

    private static func isProtocolPath(_ components: URLComponents) -> Bool {
        let pathComponents = components.path
            .split(separator: "/")
            .map(String.init)

        return pathComponents.count == 4
            && pathComponents[0] == "plugins"
            && pathComponents[2].caseInsensitiveCompare("samrock") == .orderedSame
            && pathComponents[3].caseInsensitiveCompare("protocol") == .orderedSame
    }

    private static func allowsSetupURLScheme(_ components: URLComponents) -> Bool {
        guard let scheme = components.scheme?.lowercased() else { return false }

        if scheme == "https" {
            return true
        }

        guard scheme == "http", let host = components.host?.lowercased() else {
            return false
        }

        return isLocalOrPrivateHost(host)
    }

    private static func isLocalOrPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || host == "::1" {
            return true
        }

        if host.contains(":") {
            return host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
        }

        let octets = host
            .split(separator: ".")
            .compactMap { UInt8($0) }

        guard octets.count == 4 else {
            return false
        }

        return octets[0] == 10
            || octets[0] == 127
            || (octets[0] == 172 && (16 ... 31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 169 && octets[1] == 254)
    }
}

private extension String {
    func strippingUserInfoFromAuthority() -> String {
        guard let schemeRange = range(of: "://") else {
            return self
        }

        let authorityStart = schemeRange.upperBound
        let pathStart = self[authorityStart...].firstIndex(of: "/") ?? endIndex
        let authority = self[authorityStart ..< pathStart]
        guard let userInfoEnd = authority.lastIndex(of: "@") else {
            return self
        }

        return self[..<authorityStart] + authority[authority.index(after: userInfoEnd)...] + self[pathStart...]
    }
}

final class SamRockService {
    static let shared = SamRockService()

    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func registerBitcoinOnchain(_ setup: SamRockSetupRequest, walletIndex: Int = 0) async throws {
        guard setup.requestsBitcoinOnchain else {
            throw AppError(message: t("btcpay__unsupported_text"), debugMessage: nil)
        }

        let descriptor = try await bitcoinDescriptor(walletIndex: walletIndex)
        let payload = SamRockProtocolPayload(btc: .init(descriptor: descriptor))
        let jsonData = try JSONEncoder().encode(payload)

        guard let json = String(data: jsonData, encoding: .utf8) else {
            throw AppError(message: t("btcpay__request_error"), debugMessage: nil)
        }

        var request = URLRequest(url: setup.postURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data("json=\(Self.formEncode(json))".utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw AppError(message: t("btcpay__request_error"), debugMessage: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError(message: t("btcpay__invalid_response"), debugMessage: nil)
        }

        let envelope = try? JSONDecoder().decode(SamRockResponseEnvelope.self, from: data)
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = envelope?.message ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw AppError(message: message, debugMessage: "SamRock HTTP \(httpResponse.statusCode)")
        }

        guard let envelope else {
            throw AppError(message: t("btcpay__invalid_response"), debugMessage: nil)
        }

        guard envelope.success else {
            throw AppError(message: envelope.message ?? t("btcpay__setup_failed"), debugMessage: nil)
        }

        guard let btcResult = envelope.result?.results?["BTC"] else {
            throw AppError(message: t("btcpay__missing_result"), debugMessage: nil)
        }

        guard btcResult.success else {
            throw AppError(message: btcResult.message ?? t("btcpay__rejected_descriptor"), debugMessage: nil)
        }
    }

    private func bitcoinDescriptor(walletIndex: Int) async throws -> String {
        guard let mnemonic = try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)) else {
            throw AppError(message: t("btcpay__missing_mnemonic"), debugMessage: "Unable to load mnemonic for wallet index \(walletIndex)")
        }

        let passphraseRaw = try Keychain.loadString(key: .bip39Passphrase(index: walletIndex))
        let passphrase = passphraseRaw?.isEmpty == true ? nil : passphraseRaw

        let accountType = Self.accountType(forSelectedAddressType: UserDefaults.standard.string(forKey: "selectedAddressType"))

        return try await ServiceQueue.background(.core) {
            try BitkitCore.deriveOnchainDescriptor(
                mnemonicPhrase: mnemonic,
                network: Env.bitkitCoreNetwork,
                bip39Passphrase: passphrase,
                accountType: accountType,
                accountIndex: 0
            )
        }
    }

    static func accountType(forSelectedAddressType selectedAddressType: String?) -> AccountType {
        switch selectedAddressType {
        case "legacy":
            return .legacy
        case "nestedSegwit":
            return .wrappedSegwit
        case "taproot":
            return .taproot
        case "nativeSegwit":
            return .nativeSegwit
        default:
            return .nativeSegwit
        }
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return value
            .addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: "%20", with: "+") ?? value
    }
}

private struct SamRockProtocolPayload: Encodable {
    let btc: SamRockDescriptorPayload

    enum CodingKeys: String, CodingKey {
        case btc = "BTC"
    }
}

private struct SamRockDescriptorPayload: Encodable {
    let descriptor: String

    enum CodingKeys: String, CodingKey {
        case descriptor = "Descriptor"
    }
}

struct SamRockResponseEnvelope: Decodable {
    let success: Bool
    let message: String?
    let result: SamRockSetupResponse?

    enum CodingKeys: String, CodingKey {
        case success
        case successUpper = "Success"
        case message
        case messageUpper = "Message"
        case result
        case resultUpper = "Result"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decodeIfPresent(Bool.self, forKey: .successUpper)
            ?? container.decode(Bool.self, forKey: .success)
        message = try container.decodeIfPresent(String.self, forKey: .messageUpper)
            ?? container.decodeIfPresent(String.self, forKey: .message)
        result = try container.decodeIfPresent(SamRockSetupResponse.self, forKey: .resultUpper)
            ?? container.decodeIfPresent(SamRockSetupResponse.self, forKey: .result)
    }
}

struct SamRockSetupResponse: Decodable {
    let results: [String: SamRockMethodResponse]?

    enum CodingKeys: String, CodingKey {
        case results
        case resultsUpper = "Results"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let nestedResults = try container.decodeIfPresent([String: SamRockMethodResponse].self, forKey: .resultsUpper)
            ?? container.decodeIfPresent([String: SamRockMethodResponse].self, forKey: .results)
        {
            results = nestedResults
            return
        }

        results = try? [String: SamRockMethodResponse](from: decoder)
    }
}

struct SamRockMethodResponse: Decodable {
    let success: Bool
    let message: String?

    enum CodingKeys: String, CodingKey {
        case success
        case successUpper = "Success"
        case message
        case messageUpper = "Message"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decodeIfPresent(Bool.self, forKey: .successUpper)
            ?? container.decode(Bool.self, forKey: .success)
        message = try container.decodeIfPresent(String.self, forKey: .messageUpper)
            ?? container.decodeIfPresent(String.self, forKey: .message)
    }
}
