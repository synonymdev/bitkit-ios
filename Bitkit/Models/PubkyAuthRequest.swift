import Foundation
import Paykit

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

    static func parse(url: String) throws -> PubkyAuthRequest {
        let details = try Paykit.parsePubkyAuthUrl(authUrl: url)
        let capabilities = details.capabilities ?? ""
        let permissions = parseCapabilities(capabilities)
        let serviceNames = permissions.compactMap { extractServiceName($0.path) }
        return PubkyAuthRequest(
            rawUrl: url,
            kind: details.kind,
            relay: details.relayUrl ?? "",
            capabilities: capabilities,
            permissions: permissions,
            serviceNames: serviceNames
        )
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
