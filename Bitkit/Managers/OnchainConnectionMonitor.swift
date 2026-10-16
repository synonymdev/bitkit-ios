import Foundation
import Observation

/// Tracks whether the Bitcoin network connection is known to work after the app returns from a
/// long stay in the background. Electrum servers drop idle connections, so until a wallet sync
/// succeeds again an on-chain payment could start on a connection that is being re-established.
@MainActor
@Observable
final class OnchainConnectionMonitor {
    static let shared = OnchainConnectionMonitor()

    static let backgroundThreshold: TimeInterval = 30

    /// A sync call that returned without an on-chain sync finishing after the resume.
    struct OnchainSyncPending: Error {}

    private(set) var isReconnecting = false

    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private let retryInterval: Duration

    init(retryInterval: Duration = .seconds(3)) {
        self.retryInterval = retryInterval
    }

    func appDidEnterBackground(at now: Date = Date()) {
        backgroundedAt = now
        retryTask?.cancel()
        retryTask = nil
    }

    /// Starts waiting for a successful sync when the app was in the background long enough for the
    /// server to drop the connection, or when an earlier wait has not finished.
    func appDidBecomeActive(at now: Date = Date(), sync: @escaping () async throws -> Void) {
        let wasAwayLong = backgroundedAt.map { now.timeIntervalSince($0) >= Self.backgroundThreshold } ?? false
        backgroundedAt = nil
        guard wasAwayLong || isReconnecting else { return }
        isReconnecting = true
        retryTask?.cancel()
        retryTask = Task { [weak self, retryInterval] in
            while !Task.isCancelled {
                do {
                    try await sync()
                    guard !Task.isCancelled else { return }
                    self?.isReconnecting = false
                    return
                } catch {
                    Logger.debug("Waiting for the Bitcoin network after resume: \(error)", context: "OnchainConnectionMonitor")
                }
                try? await Task.sleep(for: retryInterval)
            }
        }
    }

    /// A successful on-chain sync proves the connection works, even while the full wallet sync
    /// retried here keeps failing on an unrelated step.
    func onchainSyncDidComplete() {
        guard isReconnecting, backgroundedAt == nil else { return }
        retryTask?.cancel()
        retryTask = nil
        isReconnecting = false
    }
}
