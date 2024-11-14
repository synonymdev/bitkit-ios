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

        if let latestLightningWalletSyncTimestamp {
            debug += "\nLightning synced \(Date(timeIntervalSince1970: TimeInterval(latestLightningWalletSyncTimestamp)).description)\n"
        } else {
            debug += "\nLightning synced never\n"
        }

        if let latestOnchainWalletSyncTimestamp {
            debug += "\nOnchain synced \(Date(timeIntervalSince1970: TimeInterval(latestOnchainWalletSyncTimestamp)).description)\n"
        } else {
            debug += "\nOnchain synced never\n"
        }

        return debug
    }
}
