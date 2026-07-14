import Foundation
import Paykit

enum PubkyAuthClaim: String, Equatable {
    case watchOnlyAccountV1 = "watch-only-account-v1"

    static let queryParameter = "x-bitkit-claim"
    static let watchOnlyAccountCapabilities = "/pub/paykit/v0/bitkit/server/:rw"
}

enum PubkyAuthRequestError: Error, Equatable {
    case invalidUrl
    case duplicateBitkitClaim
    case unsupportedBitkitClaim(String)
    case invalidBitkitClaimCapabilities
}

// MARK: - PubkyAuth Permission

struct PubkyAuthPermission {
    let path: String
    let accessLevel: String

    var displayAccess: String {
        var levels: [String] = []
        if accessLevel.contains("r") { levels.append("READ") }
        if accessLevel.contains("w") { levels.append("WRITE") }
        return levels.joined(separator: ", ")
    }
}

// MARK: - PubkyAuth Request (parsed from pubkyauth:// URL)

struct PubkyAuthRequest {
    let rawUrl: String
    let kind: Paykit.PubkyAuthRequestKind
    let relay: String
    let capabilities: String
    let permissions: [PubkyAuthPermission]
    let serviceNames: [String]
    let bitkitClaim: PubkyAuthClaim?

    static func parse(url: String) throws -> PubkyAuthRequest {
        let details = try Paykit.parsePubkyAuthUrl(authUrl: url)
        let capabilities = details.capabilities ?? ""
        let permissions = parseCapabilities(capabilities)
        let serviceNames = permissions.compactMap { extractServiceName($0.path) }
        let bitkitClaim = try parseBitkitClaim(url: url, capabilities: capabilities)
        return PubkyAuthRequest(
            rawUrl: url,
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
        guard let claimValue = claimValues.first else { return nil }
        guard let claim = PubkyAuthClaim(rawValue: claimValue) else {
            throw PubkyAuthRequestError.unsupportedBitkitClaim(claimValue)
        }
        guard capabilities == PubkyAuthClaim.watchOnlyAccountCapabilities else {
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
