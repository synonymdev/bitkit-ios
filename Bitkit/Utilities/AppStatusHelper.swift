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

/// The step of a running emergency exit, named like its App Status subtitle key.
enum ExitStatusStep: String {
    case funding
    case pending
}

@MainActor
struct AppStatusHelper {
    /// Nil while no emergency exit runs. Asks for fee funding only while no payment covers it, as the progress screen does.
    nonisolated static func exitStep(record: SparkExitRecord?, fundingState: SparkExitFundingState? = nil) -> ExitStatusStep? {
        guard let record, record.isActive else { return nil }
        guard record.fundingShortfallSats != nil else { return .pending }
        switch fundingState ?? SparkExitMath.fundingState(record, utxos: nil) {
        case .paid, .seen: return .pending
        default: return .funding
        }
    }

    static func internetStatus(network: NetworkMonitor) -> HealthStatus {
        return network.isConnected ? .ready : .error
    }

    static func bitcoinNodeStatus(from wallet: WalletViewModel, network: NetworkMonitor) -> HealthStatus {
        let isOnline = network.isConnected

        guard isOnline else {
            return .error
        }

        switch wallet.nodeLifecycleState {
        case .running:
            return .ready
        case .starting, .initializing, .stopping, .stopped:
            return .pending
        case .errorStarting:
            return .error
        }
    }

    static func nodeStatus(from wallet: WalletViewModel, network: NetworkMonitor) -> HealthStatus {
        let isOnline = network.isConnected

        if !isOnline {
            return .error
        }

        switch wallet.nodeLifecycleState {
        case .running:
            return .ready
        case .starting, .initializing, .stopping, .stopped:
            return .pending
        case .errorStarting:
            return .error
        }
    }

    static func channelsStatus(from wallet: WalletViewModel, network: NetworkMonitor) -> HealthStatus {
        channelsStatus(
            isOnline: network.isConnected,
            hasUsableChannels: wallet.hasUsableChannels,
            hasChannels: wallet.channelCount > 0,
            isSparkReady: MoveToSparkMath.isSparkUsable(SparkManager.shared)
        )
    }

    static func isLightningViaSpark(from wallet: WalletViewModel, network: NetworkMonitor) -> Bool {
        isLightningViaSpark(
            isOnline: network.isConnected,
            hasUsableChannels: wallet.hasUsableChannels,
            isSparkReady: MoveToSparkMath.isSparkUsable(SparkManager.shared)
        )
    }

    /// Nil where Spark is unsupported.
    static func sparkStatus(network: NetworkMonitor) -> HealthStatus? {
        let spark = SparkManager.shared
        return sparkStatus(
            isOnline: network.isConnected,
            isSupported: spark.isSupported,
            isReady: spark.isReady,
            hasStartFailed: spark.hasStartFailed
        )
    }

    /// Spark carries Lightning when no channel can, so the connection is ready through it; red only when neither can pay.
    nonisolated static func channelsStatus(
        isOnline: Bool,
        hasUsableChannels: Bool,
        hasChannels: Bool,
        isSparkReady: Bool
    ) -> HealthStatus {
        if !isOnline {
            return .error
        }

        if hasUsableChannels || isSparkReady {
            return .ready
        } else if !hasChannels {
            return .error
        } else {
            return .pending
        }
    }

    /// No channel is usable, so Spark carries Lightning payments.
    nonisolated static func isLightningViaSpark(isOnline: Bool, hasUsableChannels: Bool, isSparkReady: Bool) -> Bool {
        isOnline && !hasUsableChannels && isSparkReady
    }

    nonisolated static func sparkStatus(isOnline: Bool, isSupported: Bool, isReady: Bool, hasStartFailed: Bool) -> HealthStatus? {
        guard isSupported else { return nil }
        guard isOnline else { return .error }
        if isReady {
            return .ready
        }
        return hasStartFailed ? .error : .pending
    }

    static func combinedAppStatus(from wallet: WalletViewModel, network: NetworkMonitor) -> HealthStatus {
        let internetState = internetStatus(network: network)
        let bitcoinNodeState = bitcoinNodeStatus(from: wallet, network: network)
        let nodeState = nodeStatus(from: wallet, network: network)

        let states = [internetState, bitcoinNodeState, nodeState]

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
