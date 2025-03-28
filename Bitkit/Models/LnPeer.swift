//
//  LnPeer.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/07/01.
//

import Foundation

struct LnPeer {
    let nodeId: String
    let address: String

    init(nodeId: String, address: String) {
        self.nodeId = nodeId
        self.address = address
    }

    init(connection: String) throws {
        let parts = connection.split(separator: "@")
        guard parts.count == 2 else {
            //            throw LnPeerError.invalidConnection
            // TODO: throw custom error
            fatalError("Invalid connection")
        }

        nodeId = String(parts[0])
        address = String(parts[1])
    }
}
