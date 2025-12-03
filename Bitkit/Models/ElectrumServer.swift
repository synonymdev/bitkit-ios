import Foundation

enum ElectrumProtocol: String, Codable {
    case tcp
    case ssl
}

struct ElectrumServer: Equatable, Codable {
    let host: String
    let port: Int
    let protocolType: ElectrumProtocol

    var url: String {
        return "\(host):\(port)"
    }

    /// Returns the full URL with protocol prefix (tcp:// or ssl://)
    var fullUrl: String {
        let protocolPrefix = protocolType == .ssl ? "ssl://" : "tcp://"
        return "\(protocolPrefix)\(host):\(port)"
    }

    var portString: String {
        return String(port)
    }

    // Convenience initializer for string port
    init(host: String, portString: String, protocolType: ElectrumProtocol) {
        self.host = host
        port = Int(portString) ?? 50001
        self.protocolType = protocolType
    }

    init(host: String, port: Int, protocolType: ElectrumProtocol) {
        self.host = host
        self.port = port
        self.protocolType = protocolType
    }
}
