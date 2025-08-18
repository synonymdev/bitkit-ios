import Foundation
import LDKNode
import SwiftUI

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

extension NodeLifecycleState {
    var statusIcon: String {
        switch self {
        case .running:
            return "power"
        case .starting, .initializing, .stopping:
            return "arrows-clockwise"
        case .stopped, .errorStarting:
            return "warning"
        }
    }

    var statusColor: Color {
        switch self {
        case .running:
            return .greenAccent
        case .starting, .initializing, .stopping:
            return .yellowAccent
        case .stopped, .errorStarting:
            return .redAccent
        }
    }
}
