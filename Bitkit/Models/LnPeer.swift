//
//  LnPeer.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/01.
//

import Foundation

enum LnPeerError: Error {
    case invalidConnection
    case invalidAddressFormat
}

extension LnPeerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidConnection:
            return NSLocalizedString("Invalid lightning node connection format. Expected format: nodeId@host:port", comment: "")
        case .invalidAddressFormat:
            return NSLocalizedString("Invalid lightning node address format. Expected format: host:port", comment: "")
        }
    }
}

struct LnPeer {
    let nodeId: String
    let host: String
    let port: UInt16
    
    var address: String {
        return "\(host):\(port)"
    }

    init(nodeId: String, host: String, port: UInt16) {
        self.nodeId = nodeId
        self.host = host
        self.port = port
    }

    init(connection: String) throws {
        let parts = connection.split(separator: "@")
        guard parts.count == 2 else {
            throw LnPeerError.invalidConnection
        }

        nodeId = String(parts[0])
        
        let addressParts = parts[1].split(separator: ":")
        guard addressParts.count == 2, let port = UInt16(addressParts[1]) else {
            throw LnPeerError.invalidAddressFormat
        }
        
        host = String(addressParts[0])
        self.port = port
    }
}
