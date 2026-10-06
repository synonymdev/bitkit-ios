import SwiftUI

/// Tells a return from the background apart from a brief `.inactive` phase (Control Center, notification shade,
/// Face ID prompt) that never left the foreground.
struct ForegroundReturnTracker {
    private var wasInBackground = false

    /// Records the phase and returns true when it is an `.active` phase that follows a `.background` one.
    mutating func scenePhaseChanged(to phase: ScenePhase) -> Bool {
        switch phase {
        case .background:
            wasInBackground = true
            return false
        case .active:
            defer { wasInBackground = false }
            return wasInBackground
        default:
            return false
        }
    }
}

/// Restarts a node that failed to start on behalf of the app lifecycle, without leaving it running under recovery mode.
@MainActor
struct NodeRestarter {
    var nodeState: () -> NodeLifecycleState
    var isConnected: () -> Bool
    var walletExists: () -> Bool?
    var isRecoveryShown: () -> Bool
    /// Starts the wallet; the flag says whether a failed start plays the error haptic.
    var start: (_ playsErrorHaptic: Bool) async -> Void
    var stop: () async throws -> Void

    /// Schedules a restart when the app returned from the background while a wallet exists, the network is connected,
    /// the node is in the error-starting state and the Recovery screen is not shown.
    @discardableResult
    func retryOnForeground(returnedFromBackground: Bool) -> Task<Void, Never>? {
        guard returnedFromBackground, isConnected(), walletExists() == true, !isRecoveryShown(), case .errorStarting = nodeState() else {
            return nil
        }
        return restart(reason: "App returned to foreground")
    }

    /// Starts the wallet unless Recovery is shown. A start the user did not trigger is silent on failure, and a node it
    /// started while Recovery opened is stopped once the start completes.
    @discardableResult
    func restart(reason: String) -> Task<Void, Never> {
        Task {
            // Checked when the task runs, because the Recovery quick action can be handled after the caller decided to restart.
            guard !isRecoveryShown() else {
                Logger.info("\(reason), skipping wallet start in recovery mode", context: "NodeRestarter")
                return
            }
            Logger.info("\(reason), retrying wallet start...", context: "NodeRestarter")
            await start(false)

            // Recovery can open while the start is in flight; stop the node this restart started instead of leaving it running.
            if isRecoveryShown(), nodeState() == .running {
                Logger.info("\(reason), stopping the node started while recovery mode opened", context: "NodeRestarter")
                do {
                    try await stop()
                } catch {
                    Logger.warn("Failed to stop the node under recovery mode: \(error)", context: "NodeRestarter")
                }
            }
        }
    }
}
