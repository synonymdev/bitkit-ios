import SwiftUI

enum HealthStatus: String {
    case ready
    case pending
    case error

    var iconBackground: Color {
        switch self {
        case .ready: return .green16
        case .pending: return .yellow16
        case .error: return .red16
        }
    }

    var iconColor: Color {
        switch self {
        case .ready: return .greenAccent
        case .pending: return .yellowAccent
        case .error: return .redAccent
        }
    }
}

@MainActor
struct AppStatusHelper {
    static func internetStatus(network: NetworkMonitor) -> HealthStatus {
        return network.isConnected ? .ready : .error
    }

    static func nodeStatus(from wallet: WalletViewModel, network: NetworkMonitor) -> HealthStatus {
        let isOnline = network.isConnected

        switch wallet.nodeLifecycleState {
        case .running:
            return isOnline ? .ready : .error
        case .starting, .initializing, .stopping:
            return .pending
        case .stopped, .errorStarting:
            return .error
        }
    }

    static func channelsStatus(from wallet: WalletViewModel) -> HealthStatus {
        let hasChannels = wallet.channelCount > 0
        let hasUsableChannels = wallet.channels?.contains(where: \.isUsable) ?? false

        if !hasChannels {
            return .error
        } else if hasUsableChannels {
            return .ready
        } else {
            return .pending
        }
    }

    static func combinedAppStatus(from wallet: WalletViewModel, network: NetworkMonitor) -> HealthStatus {
        let internetState = internetStatus(network: network)
        let nodeState = nodeStatus(from: wallet, network: network)

        let states = [internetState, nodeState]

        // If any component is in error state, return error
        if states.contains(.error) {
            return .error
        }

        // If any component is pending, return pending
        if states.contains(.pending) {
            return .pending
        }

        // All components are ready
        return .ready
    }
}
