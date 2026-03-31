import BitkitCore
import Foundation

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
    let kind: String
    let relay: String
    let permissions: [PubkyAuthPermission]
    let serviceNames: [String]

    /// Parse a `pubkyauth://` URL into a display-ready request.
    /// Uses BitkitCore FFI `parsePubkyAuthUrl` for URL parsing, then extracts permissions from caps.
    static func parse(url: String) throws -> PubkyAuthRequest {
        let details = try parsePubkyAuthUrl(authUrl: url)
        let permissions = parseCapabilities(details.capabilities)
        let serviceNames = permissions.compactMap { extractServiceName($0.path) }
        return PubkyAuthRequest(
            rawUrl: url,
            kind: details.kind,
            relay: details.relay,
            permissions: permissions,
            serviceNames: serviceNames
        )
    }

    /// Parse a capabilities string like `/pub/pubky.app/:rw,/pub/paykit/v0/:rw`
    /// into individual permission entries.
    static func parseCapabilities(_ caps: String) -> [PubkyAuthPermission] {
        caps
            .split(separator: ",")
            .compactMap { segment -> PubkyAuthPermission? in
                let trimmed = segment.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }

                // Find the last `:` that separates path from access flags
                // e.g., "/pub/pubky.app/:rw" → path="/pub/pubky.app/", access="rw"
                guard let lastColon = trimmed.lastIndex(of: ":") else { return nil }

                let path = String(trimmed[trimmed.startIndex ..< lastColon])
                let access = String(trimmed[trimmed.index(after: lastColon)...])

                guard !path.isEmpty, !access.isEmpty else { return nil }

                return PubkyAuthPermission(path: path, accessLevel: access)
            }
    }

    /// Extract a human-readable service name from a permission path.
    /// e.g., "/pub/pubky.app/" → "pubky.app", "/pub/paykit/v0/" → "paykit"
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
