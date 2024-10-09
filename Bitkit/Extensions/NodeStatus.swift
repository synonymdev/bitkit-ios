//
//  NodeStatus.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/04.
//

import Foundation
import LDKNode

extension NodeStatus {
    var debugState: String {
        var debug = """
        Running: \(isRunning ? "✅" : "❌")
        Current best block \(currentBestBlock.height)
        """

        if let latestWalletSyncTimestamp {
            debug += "\nLast synced \(Date(timeIntervalSince1970: TimeInterval(latestWalletSyncTimestamp)).description)\n"
        } else {
            debug += "\nLast synced never\n"
        }

        return debug
    }
}
