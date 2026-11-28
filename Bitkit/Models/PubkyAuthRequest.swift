import BitkitCore
import Foundation
import Paykit

struct PubkyAuthClaim: Equatable {
    private enum Item: String {
        case paykitAccessV1 = "paykit-access-v1"
        case watchOnlyAccountV1 = "watch-only-account-v1"
        case usdtAddressV1 = "usdt-address-v1"
    }

    static let watchOnlyAccountV1 = Self(items: [.watchOnlyAccountV1])
    static let paykitAccessV1 = Self(items: [.paykitAccessV1])
    static let usdtAddressV1 = Self(items: [.usdtAddressV1])
    static let bitcoinAndUsdt = Self(items: [.watchOnlyAccountV1, .usdtAddressV1])

    private let items: [Item]

    private init(items: [Item]) {
        self.items = items
    }

    init?(rawValue: String) {
        let values = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        let items = values.compactMap { Item(rawValue: String($0)) }
        guard !items.isEmpty, items.count == values.count, Set(items).count == items.count else { return nil }
        self.items = items
    }

    var rawValue: String {
        // Preserve the requested order because the SDK binds this value into the signature and relay channel.
        items.map(\.rawValue).joined(separator: ".")
    }

    static let queryParameter = "x-bitkit-claim"
    static let requiredCapabilities = Paykit.requiredSessionCapabilities()

    var includesWatchOnlyAccount: Bool {
        items.contains(.watchOnlyAccountV1)
    }

    var includesPaykitAccess: Bool {
        items.contains(.paykitAccessV1)
    }

    var sharesBitcoin: Bool {
        includesWatchOnlyAccount
    }

    var sharesUsdt: Bool {
        items.contains(.usdtAddressV1)
    }

    var sharesReceivingDetails: Bool {
        sharesBitcoin || sharesUsdt
    }

    var requiresUsdtAddress: Bool {
        sharesUsdt && !sharesBitcoin && !includesPaykitAccess
    }

    func unsignedPayload(account: WatchOnlyAccountRecord?, usdtEndpoint: PublicPaykitService.Endpoint?) throws -> Data? {
        guard sharesUsdt else {
            return try account.map { try WatchOnlyAccountClaimCodec.encode(record: $0) }
        }
        var payload: [String: Any] = [:]
        if let usdtEndpoint {
            guard usdtEndpoint.methodId == .usdtArbitrum,
                  PaykitUsdt.address(from: usdtEndpoint.rawPayload) == usdtEndpoint.value
            else { throw PubkyAuthRequestError.invalidPaymentDetails }
            payload[PublicPaykitService.MethodId.usdtArbitrum.rawValue] = try JSONSerialization.jsonObject(with: Data(usdtEndpoint.rawPayload.utf8))
        }
        if sharesBitcoin {
            guard let account else { throw PubkyAuthRequestError.invalidPaymentDetails }
            _ = try WatchOnlyAccountClaimCodec.encode(record: account)
            payload["bitcoin_account"] = ["account_index": account.accountIndex, "address_type": account.addressType, "xpub": account.xpub]
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    func encode(accountPayload: Data?, paykitKey: PaykitIdentitySecretKey?) throws -> Data {
        if sharesUsdt {
            guard let accountPayload,
                  var payload = try JSONSerialization.jsonObject(with: accountPayload) as? [String: Any],
                  includesPaykitAccess == (paykitKey != nil)
            else { throw PubkyAuthRequestError.invalidPaymentDetails }
            if let paykitKey {
                payload["paykit_access"] = [
                    "key_generation": paykitKey.keyGeneration(),
                    "secret": paykitKey.exportBytes().base64EncodedString()
                        .replacingOccurrences(of: "+", with: "-")
                        .replacingOccurrences(of: "/", with: "_")
                        .replacingOccurrences(of: "=", with: ""),
                ]
            }
            return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        }
        guard includesWatchOnlyAccount == (accountPayload != nil),
              includesPaykitAccess == (paykitKey != nil)
        else {
            throw PubkyAuthRequestError.invalidUrl
        }
        if let accountPayload,
           accountPayload.count != WatchOnlyAccountClaimCodec.payloadLength || accountPayload.first != 1
        {
            throw WatchOnlyAccountError.invalidExtendedPublicKey
        }
        var payload = accountPayload ?? Data([1])
        if let paykitKey {
            payload.append(contentsOf: withUnsafeBytes(of: paykitKey.keyGeneration().bigEndian, Array.init))
            payload.append(paykitKey.exportBytes())
        }
        return payload
    }

    static func matchesRequiredCapabilities(_ capabilities: String) -> Bool {
        capabilities
            .split(separator: ",", omittingEmptySubsequences: false)
            .allSatisfy { $0.trimmingCharacters(in: .whitespaces) == requiredCapabilities }
    }
}

enum PubkyAuthRequestError: Error, Equatable {
    case invalidUrl
    case invalidPaymentDetails
    case missingBitkitClaim
    case duplicateBitkitClaim
    case duplicateRelay
    case duplicateSecret
    case unsupportedBitkitClaim(String)
    case invalidBitkitClaimCapabilities
    case signerMismatch(expectedSigner: String)
}

// MARK: - PubkyAuth Permission

struct PubkyAuthPermission {
    let path: String
    let accessLevel: String

    var displayPath: String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    var displayAccess: String {
        var levels: [String] = []
        if accessLevel.contains("r") {
            levels.append("READ")
        }
        if accessLevel.contains("w") {
            levels.append("WRITE")
        }
        return levels.joined(separator: ", ")
    }
}

// MARK: - PubkyAuth Request

struct PubkyAuthRequest {
    private static let bitkitHandoffHost = "pubky-auth"
    /// `/setup` is Paykit setup and must carry a Bitkit claim; `/signin` is a plain grant sign-in.
    private static let bitkitSetupPath = "/setup"
    private static let bitkitSigninPath = "/signin"

    let rawUrl: String
    let kind: Paykit.PubkyAuthRequestKind
    let clientID: String
    let relay: String
    let capabilities: String
    let permissions: [PubkyAuthPermission]
    let serviceNames: [String]
    let bitkitClaim: PubkyAuthClaim?
    let homeserverPublicKey: String?
    let signupToken: String?
    let authorizationUrl: String?
    /// The only pubky that may approve this request (`spk`), as bare z-base-32. Nil when the request names none.
    let expectedSigner: String?

    var isSignup: Bool {
        Self.isSignupURL(rawUrl)
    }

    var isGrantSignup: Bool {
        guard let components = URLComponents(string: rawUrl) else { return false }
        return components.scheme?.lowercased() == "pubkyauth" && components.host?.lowercased() == "signup_grant"
    }

    func requiresIdentityCreation(hasIdentity: Bool) -> Bool {
        isSignup && (!isGrantSignup || !hasIdentity)
    }

    /// The relay URL that receives the authorization, without user info or fragment so the host cannot be disguised.
    /// This is a delivery destination, not a service identity. Nil only when the request has no relay.
    var relayDisplayUrl: String? {
        Self.displayRelay(relay)
    }

    /// The relay as shown on the approval sheet: scheme, host, port, path and query, exactly as the Pubky SDK's URL parser
    /// keeps them. Nil when `relay` is not already in that form apart from letter case, user info, the fragment and a
    /// missing root path: a space, control or non-ASCII characters, a backslash before the query, characters the parser
    /// percent-encodes in the path or in the query, a missing, percent-encoded or non-canonical host, a default, padded
    /// or out-of-range port, or a `.` or `..` path segment.
    static func displayRelay(_ relay: String) -> String? {
        // rust-url 2.5.8 (`url/src/parser.rs`): the `PATH` set is percent-encoded in a path and a backslash becomes a
        // slash; a query of an http(s) URL percent-encodes the `SPECIAL_QUERY` set.
        let pathRewritten = "\\\"<>`{}"
        let queryRewritten = "\"<>'"
        guard relay.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }),
              let schemeEnd = relay.range(of: "://"), schemeEnd.lowerBound > relay.startIndex
        else { return nil }
        let scheme = relay[..<schemeEnd.lowerBound].lowercased()
        guard let defaultPort = ["http": 80, "https": 443][scheme] else { return nil }
        let rest = relay[schemeEnd.upperBound...]
        let authorityEnd = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
        let authority = rest[..<authorityEnd]
        let hostPort = authority[(authority.lastIndex(of: "@").map { authority.index(after: $0) } ?? authority.startIndex)...]
            .lowercased()
        let pathAndQuery = rest[authorityEnd...].prefix { $0 != "#" }
        let path = pathAndQuery.prefix { $0 != "?" }
        let query = pathAndQuery[path.endIndex...].dropFirst()
        let hasDotSegment = path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { [".", ".."].contains($0.lowercased().replacingOccurrences(of: "%2e", with: ".")) }
        let isRewritten = authority.contains("\\") || path.contains { pathRewritten.contains($0) }
            || query.contains { queryRewritten.contains($0) } || hasDotSegment
        guard !isRewritten, isUnchangedRelayHostPort(hostPort, defaultPort: defaultPort) else { return nil }
        return "\(scheme)://\(hostPort)\(pathAndQuery.hasPrefix("/") ? "" : "/")\(pathAndQuery)"
    }

    private static func isUnchangedRelayHostPort(_ hostPort: String, defaultPort: Int) -> Bool {
        let matches = { (pattern: String, value: String) in
            value.range(of: "^(?:\(pattern))$", options: .regularExpression) != nil && !value.contains("\n")
        }
        guard matches(#"(\[[0-9a-f:.]+\]|[a-z0-9._~-]+)(:[0-9]{1,5})?"#, hostPort) else { return false }
        let portStart = hostPort.hasSuffix("]") ? nil : hostPort.lastIndex(of: ":")
        let host = String(hostPort[..<(portStart ?? hostPort.endIndex)])
        if let portStart {
            let portText = String(hostPort[hostPort.index(after: portStart)...])
            guard let port = Int(portText), String(port) == portText, port <= 65535, port != defaultPort else { return false }
        }
        if host.hasPrefix("[") {
            return isCanonicalIpv6(String(host.dropFirst().dropLast()))
        }
        // A last label that reads as a number makes the SDK's URL parser treat the whole host as an IPv4 address.
        let trimmedHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        let lastLabel = String(trimmedHost.split(separator: ".", omittingEmptySubsequences: false).last ?? "")
        let octet = "(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"
        return !matches("[0-9]+|0x[0-9a-f]*", lastLabel) || matches("(\(octet)\\.){3}\(octet)", host)
    }

    private static func isCanonicalIpv6(_ address: String) -> Bool {
        let halves = address.components(separatedBy: "::")
        let head = halves[0].split(separator: ":").map(String.init)
        let tail = halves.count > 1 ? halves[1].split(separator: ":").map(String.init) : []
        let missing = 8 - head.count - tail.count
        let isComplete = halves.count == 1 ? missing == 0 : halves.count == 2 && missing >= 1
        guard isComplete, !address.contains(".") else { return false }
        let parsed = (head + Array(repeating: "0", count: missing) + tail).map { Int($0, radix: 16) }
        let groups = parsed.compactMap { $0 }
        guard groups.count == 8, groups.allSatisfy({ $0 <= 0xFFFF }) else { return false }
        var runStart = 0
        var runLength = 0
        var index = 0
        while index < groups.count {
            let end = groups[index...].firstIndex { $0 != 0 } ?? groups.count
            if end - index > runLength {
                runStart = index
                runLength = end - index
            }
            index = max(end, index + 1)
        }
        let hex = { (part: ArraySlice<Int>) in part.map { String($0, radix: 16) }.joined(separator: ":") }
        let canonical = runLength < 2
            ? hex(groups[...])
            : "\(hex(groups[..<runStart]))::\(hex(groups[(runStart + runLength)...]))"
        return canonical == address
    }

    static func isProtocolURL(_ value: String) -> Bool {
        let normalizedURL = normalizedProtocolURL(value)
        guard let components = URLComponents(string: normalizedURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }

        switch components.scheme?.lowercased() {
        case "pubkyauth":
            return true
        case "pubkyring":
            return components.host?.lowercased() == "signup"
        default:
            return false
        }
    }

    /// Normalizes Bitkit's unique iOS handoffs because the OS cannot deterministically route a custom scheme shared with Pubky Ring.
    static func normalizedProtocolURL(_ value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bitkitHandoffPath(trimmedValue) != nil,
              let queryDelimiter = trimmedValue.firstIndex(of: "?")
        else {
            return value
        }

        let queryStart = trimmedValue.index(after: queryDelimiter)
        return "pubkyauth://signin_grant?\(trimmedValue[queryStart...])"
    }

    static func parse(url: String) throws -> PubkyAuthRequest {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let requiresBitkitClaim = bitkitHandoffPath(trimmedURL) == bitkitSetupPath
        let normalizedURL = normalizedProtocolURL(trimmedURL)
        try rejectDuplicateRelayAndSecret(in: normalizedURL)

        if requiresBitkitClaim {
            let capabilities = URLComponents(string: normalizedURL)?.queryItems?
                .first { $0.name == "caps" }?.value ?? ""
            _ = try parseBitkitClaim(url: normalizedURL, capabilities: capabilities, requiresBitkitClaim: true)
        }

        if let components = URLComponents(string: normalizedURL), isSignupURL(components),
           components.host?.lowercased() != "signup_grant"
        {
            return try parseSignup(url: normalizedURL, components: components)
        }

        let details = try Paykit.parsePubkyAuthUrl(authUrl: normalizedURL)
        var signupToken: String?
        if details.kind == .signUp {
            let values = Dictionary(grouping: URLComponents(string: normalizedURL)?.queryItems ?? [], by: \.name)
            _ = try requiredQueryValue("hs", from: values)
            signupToken = try optionalQueryValue("st", from: values)
        }
        let capabilities = details.capabilities
        return try makeRequest(
            url: normalizedURL,
            kind: details.kind,
            clientID: details.clientId,
            relay: details.relayUrl,
            capabilities: capabilities,
            homeserverPublicKey: details.homeserverPublicKey,
            signupToken: signupToken,
            authorizationUrl: normalizedURL,
            requiresBitkitClaim: requiresBitkitClaim
        )
    }

    static func isSignupURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value) else { return false }
        return isSignupURL(components)
    }

    private static func isSignupURL(_ components: URLComponents) -> Bool {
        switch components.scheme?.lowercased() {
        case "pubkyring":
            return components.host?.lowercased() == "signup"
        case "pubkyauth":
            return ["direct_signup", "signup", "signup_grant"].contains(components.host?.lowercased())
        default:
            return false
        }
    }

    private static func parseSignup(url: String, components: URLComponents) throws -> PubkyAuthRequest {
        let values = Dictionary(grouping: components.queryItems ?? [], by: \.name)
        let homeserver = try requiredQueryValue("hs", from: values)
        let authorizesApp = components.scheme?.lowercased() == "pubkyring" ||
            (
                components.scheme?.lowercased() == "pubkyauth" &&
                    components.host?.lowercased() == "signup" &&
                    ["relay", "secret", "caps"].contains { values[$0] != nil }
            )
        let relay = authorizesApp ? try requiredQueryValue("relay", from: values) : ""
        let secret = authorizesApp ? try requiredQueryValue("secret", from: values) : ""
        let capabilities = authorizesApp ? try requiredQueryValue("caps", from: values) : ""
        let authorizationUrl = authorizesApp
            ? ringAuthorizationUrl(relay: relay, secret: secret, capabilities: capabilities)
            : nil
        do {
            if let authorizationUrl {
                _ = try BitkitCore.parsePubkyAuthUrl(authUrl: authorizationUrl)
            }
            _ = try Paykit.normalizePubkyPublicKey(value: homeserver)
        } catch {
            throw PubkyAuthRequestError.invalidUrl
        }
        let request = try makeRequest(
            url: url,
            kind: .signUp,
            clientID: "",
            relay: relay,
            capabilities: capabilities,
            homeserverPublicKey: homeserver,
            signupToken: optionalQueryValue("st", from: values),
            authorizationUrl: authorizationUrl
        )
        guard request.bitkitClaim == nil else {
            throw PubkyAuthRequestError.invalidUrl
        }
        return request
    }

    private static func makeRequest(
        url: String,
        kind: Paykit.PubkyAuthRequestKind,
        clientID: String,
        relay: String,
        capabilities: String,
        homeserverPublicKey: String?,
        signupToken: String?,
        authorizationUrl: String?,
        requiresBitkitClaim: Bool = false
    ) throws -> PubkyAuthRequest {
        let permissions = parseCapabilities(capabilities)
        var seenServiceNames = Set<String>()
        let serviceNames = permissions
            .compactMap { extractServiceName($0.path) }
            .filter { seenServiceNames.insert($0).inserted }
        let bitkitClaim = try parseBitkitClaim(url: url, capabilities: capabilities, requiresBitkitClaim: requiresBitkitClaim)
        guard relay.isEmpty || displayRelay(relay) != nil else {
            throw PubkyAuthRequestError.invalidUrl
        }
        let expectedSigner = try parseExpectedSigner(url: url)
        return PubkyAuthRequest(
            rawUrl: url,
            kind: kind,
            clientID: clientID,
            relay: relay,
            capabilities: capabilities,
            permissions: permissions,
            serviceNames: serviceNames,
            bitkitClaim: bitkitClaim,
            homeserverPublicKey: homeserverPublicKey,
            signupToken: signupToken,
            authorizationUrl: authorizationUrl,
            expectedSigner: expectedSigner
        )
    }

    /// Reads the pubky a sign-in request must be approved with. Absent is fine; a repeated value or anything other than
    /// a bare canonical z-base-32 key makes the request invalid, as in the Pubky SDK parser for `signin_grant`. Only
    /// signup requests ignore the parameter, so a sign-in this parser reads differently from the SDK is still held to it.
    /// Upstream reads `spk` for `signin_grant` alone (pubky/pubky-homeserver at d95161af3e:
    /// `pubky-sdk/src/actors/auth/deep_links/signin_grant.rs:106` is the only caller of `parse_expected_signer`,
    /// `deep_link.rs:211` tests that `signin` and `signup_grant` ignore it, `docs/AUTH.md:81`).
    static func parseExpectedSigner(url: String) throws -> String? {
        // The SDK's URL parser drops tabs and line breaks, while `URLComponents` percent-encodes them, so a control
        // character could hide `spk` from this parser only.
        guard !url.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              let components = URLComponents(string: url)
        else {
            throw PubkyAuthRequestError.invalidUrl
        }
        guard !isSignupURL(components) else { return nil }
        let values = components.queryItems?.filter { $0.name == "spk" }.map { $0.value ?? "" } ?? []
        guard let value = values.first else { return nil }
        // 52 z-base-32 symbols encode 260 bits, so the last symbol of a 32-byte key carries a single bit.
        guard values.count == 1,
              value.range(of: "^[ybndrfg8ejkmcpqxot1uwisza345h769]{51}[yo]$", options: .regularExpression) != nil,
              value.utf8.count == 52,
              (try? Paykit.normalizePubkyPublicKey(value: value)) != nil
        else {
            throw PubkyAuthRequestError.invalidUrl
        }
        return value
    }

    /// Whether `publicKey`, bare or with the `pubky` prefix, may approve a request naming `expectedSigner`.
    static func isExpectedSigner(_ expectedSigner: String?, publicKey: String) -> Bool {
        guard let expectedSigner else { return true }
        let isPrefixed = publicKey.count == 57 && publicKey.hasPrefix("pubky")
        return expectedSigner == (isPrefixed ? String(publicKey.dropFirst(5)) : publicKey)
    }

    /// Throws before anything is signed when `authUrl` names a pubky other than the one `secretKeyHex` signs with.
    static func requireExpectedSigner(authUrl: String, signerPublicKey: () throws -> String) throws {
        guard let expectedSigner = try parseExpectedSigner(url: authUrl) else { return }
        guard try isExpectedSigner(expectedSigner, publicKey: signerPublicKey()) else {
            throw PubkyAuthRequestError.signerMismatch(expectedSigner: expectedSigner)
        }
    }

    private static func ringAuthorizationUrl(relay: String, secret: String, capabilities: String) -> String {
        "pubkyauth:///?relay=\(encodeQueryComponent(relay))" +
            "&secret=\(encodeQueryComponent(secret))&caps=\(encodeQueryComponent(capabilities))"
    }

    private static func encodeQueryComponent(_ value: String) -> String {
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func requiredQueryValue(
        _ name: String,
        from values: [String: [URLQueryItem]]
    ) throws -> String {
        guard let value = try optionalQueryValue(name, from: values), !value.isEmpty else {
            throw PubkyAuthRequestError.invalidUrl
        }
        return value
    }

    private static func optionalQueryValue(
        _ name: String,
        from values: [String: [URLQueryItem]]
    ) throws -> String? {
        let items = values[name] ?? []
        guard items.count <= 1 else {
            throw PubkyAuthRequestError.invalidUrl
        }
        return items.first?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func rejectDuplicateRelayAndSecret(in url: String) throws {
        guard let items = URLComponents(string: url)?.queryItems else { return }
        if items.filter({ $0.name == "relay" }).count > 1 {
            throw PubkyAuthRequestError.duplicateRelay
        }
        if items.filter({ $0.name == "secret" }).count > 1 {
            throw PubkyAuthRequestError.duplicateSecret
        }
    }

    static func parseBitkitClaim(url: String, capabilities: String, requiresBitkitClaim: Bool = false) throws -> PubkyAuthClaim? {
        guard let components = URLComponents(string: url) else {
            throw PubkyAuthRequestError.invalidUrl
        }

        let claimValues = components.queryItems?
            .filter { $0.name == PubkyAuthClaim.queryParameter }
            .map { $0.value ?? "" } ?? []

        guard claimValues.count <= 1 else {
            throw PubkyAuthRequestError.duplicateBitkitClaim
        }
        guard let claimValue = claimValues.first else {
            if requiresBitkitClaim {
                throw PubkyAuthRequestError.missingBitkitClaim
            }
            return nil
        }
        guard let claim = PubkyAuthClaim(rawValue: claimValue) else {
            throw PubkyAuthRequestError.unsupportedBitkitClaim(claimValue)
        }
        guard PubkyAuthClaim.matchesRequiredCapabilities(capabilities) else {
            throw PubkyAuthRequestError.invalidBitkitClaimCapabilities
        }

        return claim
    }

    /// Returns the handoff path of a `bitkit://pubky-auth/setup?…` or `bitkit://pubky-auth/signin?…` link.
    private static func bitkitHandoffPath(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "bitkit",
              components.host?.lowercased() == bitkitHandoffHost,
              [bitkitSetupPath, bitkitSigninPath].contains(components.path),
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              let query = components.percentEncodedQuery,
              !query.isEmpty,
              !query.hasPrefix("?")
        else {
            return nil
        }

        return components.path
    }

    static func parseCapabilities(_ caps: String) -> [PubkyAuthPermission] {
        caps
            .split(separator: ",")
            .compactMap { segment -> PubkyAuthPermission? in
                let trimmed = segment.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, let lastColon = trimmed.lastIndex(of: ":") else { return nil }

                let path = String(trimmed[trimmed.startIndex ..< lastColon])
                let access = String(trimmed[trimmed.index(after: lastColon)...])

                guard !path.isEmpty, !access.isEmpty else { return nil }

                return PubkyAuthPermission(path: path, accessLevel: access)
            }
    }

    static func extractServiceName(_ path: String) -> String? {
        let components = path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")

        // Skip "pub" prefix, take the next meaningful component
        guard components.count >= 2 else { return nil }
        let name = String(components[1])
        return name.isEmpty ? nil : name
    }
}
