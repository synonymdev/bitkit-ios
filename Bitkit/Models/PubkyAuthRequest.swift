import Foundation
import Paykit

enum PubkyAuthClaim: String, Equatable {
    case watchOnlyAccountV1 = "watch-only-account-v1"

    static let queryParameter = "x-bitkit-claim"
    static let watchOnlyAccountCapabilities = "/pub/paykit/v0/bitkit/server/:rw,/pub/paykit/v0/private/bitkit/server/:rw"
    private static let watchOnlyAccountCapabilitySet = Set(watchOnlyAccountCapabilities.split(separator: ",").map(String.init))

    static func matchesWatchOnlyAccountCapabilities(_ capabilities: String) -> Bool {
        guard let requestedCapabilitySet = capabilitySet(capabilities) else { return false }
        return requestedCapabilitySet == watchOnlyAccountCapabilitySet
    }

    private static func capabilitySet(_ capabilities: String) -> Set<String>? {
        let entries = capabilities
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !entries.contains(where: \.isEmpty) else { return nil }
        return Set(entries)
    }
}

enum PubkyAuthRequestError: Error, Equatable {
    case invalidUrl
    case missingBitkitClaim
    case duplicateBitkitClaim
    case unsupportedBitkitClaim(String)
    case invalidBitkitClaimCapabilities
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
        if accessLevel.contains("r") { levels.append("READ") }
        if accessLevel.contains("w") { levels.append("WRITE") }
        return levels.joined(separator: ", ")
    }
}

// MARK: - PubkyAuth Request (parsed from pubkyauth:// URL)

struct PubkyAuthRequest {
    private static let bitkitSetupHost = "pubky-auth"
    private static let bitkitSetupPath = "/setup"

    let rawUrl: String
    let kind: Paykit.PubkyAuthRequestKind
    let relay: String
    let capabilities: String
    let permissions: [PubkyAuthPermission]
    let serviceNames: [String]
    let bitkitClaim: PubkyAuthClaim?

    static func isProtocolURL(_ value: String) -> Bool {
        URLComponents(string: normalizedProtocolURL(value).trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased() == "pubkyauth"
    }

    /// Normalizes Bitkit's unique iOS handoff because the OS cannot deterministically route a custom scheme shared with Pubky Ring.
    static func normalizedProtocolURL(_ value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmedValue),
              components.scheme?.lowercased() == "bitkit",
              components.host?.lowercased() == bitkitSetupHost,
              components.path == bitkitSetupPath,
              components.user == nil,
              components.password == nil,
              components.port == nil
        else {
            return value
        }

        let fragmentDelimiter = trimmedValue.firstIndex(of: "#") ?? trimmedValue.endIndex
        guard let queryDelimiter = trimmedValue[..<fragmentDelimiter].firstIndex(of: "?") else {
            return "pubkyauth://signin"
        }

        let queryStart = trimmedValue.index(after: queryDelimiter)
        return "pubkyauth://signin?\(trimmedValue[queryStart ..< fragmentDelimiter])"
    }

    static func parse(url: String) throws -> PubkyAuthRequest {
        let normalizedURL = normalizedProtocolURL(url)
        let details = try Paykit.parsePubkyAuthUrl(authUrl: normalizedURL)
        let capabilities = details.capabilities ?? ""
        let permissions = parseCapabilities(capabilities)
        var seenServiceNames = Set<String>()
        let serviceNames = permissions
            .compactMap { extractServiceName($0.path) }
            .filter { seenServiceNames.insert($0).inserted }
        let bitkitClaim = try parseBitkitClaim(url: normalizedURL, capabilities: capabilities)
        return PubkyAuthRequest(
            rawUrl: normalizedURL,
            kind: details.kind,
            relay: details.relayUrl ?? "",
            capabilities: capabilities,
            permissions: permissions,
            serviceNames: serviceNames,
            bitkitClaim: bitkitClaim
        )
    }

    static func parseBitkitClaim(url: String, capabilities: String) throws -> PubkyAuthClaim? {
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
            if PubkyAuthClaim.matchesWatchOnlyAccountCapabilities(capabilities) {
                throw PubkyAuthRequestError.missingBitkitClaim
            }
            return nil
        }
        guard let claim = PubkyAuthClaim(rawValue: claimValue) else {
            throw PubkyAuthRequestError.unsupportedBitkitClaim(claimValue)
        }
        guard PubkyAuthClaim.matchesWatchOnlyAccountCapabilities(capabilities) else {
            throw PubkyAuthRequestError.invalidBitkitClaimCapabilities
        }

        return claim
    }

    static func parseCapabilities(_ caps: String) -> [PubkyAuthPermission] {
        caps
            .split(separator: ",")
            .compactMap { segment -> PubkyAuthPermission? in
                let trimmed = segment.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }

                guard let lastColon = trimmed.lastIndex(of: ":") else { return nil }

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
