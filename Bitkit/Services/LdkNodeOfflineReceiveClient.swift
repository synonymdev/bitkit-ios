#if OFFLINE_RECEIVE_LOCAL_LDK
    import Foundation
    import LDKNode

    /// Bridges the generated `OfflineReceivePayment` API of the local ldk-node binding onto the
    /// app-side client protocol. Compiled only when the build carries that binding.
    struct LdkNodeOfflineReceiveClient: OfflineReceiveNodeClient {
        let lightningService: LightningService

        init(lightningService: LightningService = .shared) {
            self.lightningService = lightningService
        }

        func nodeId() async throws -> String {
            try await onLdkQueue { try lightningService.offlineReceiveNodeId() }
        }

        func canReceive(amountMsat: UInt64) async throws -> Bool {
            try await onLdkQueue { try lightningService.offlineReceivePayment().canReceive(amountMsat: amountMsat) }
        }

        func prepare(requestId: String, amountMsat: UInt64, description: String) async throws -> OfflineReceiveNodeStatus {
            try await onLdkQueue {
                try OfflineReceiveNodeStatus(
                    lightningService.offlineReceivePayment().prepare(requestId: requestId, amountMsat: amountMsat, description: description)
                )
            }
        }

        func status(requestId: String) async throws -> OfflineReceiveNodeStatus {
            try await onLdkQueue { try OfflineReceiveNodeStatus(lightningService.offlineReceivePayment().status(requestId: requestId)) }
        }

        func cancel(requestId: String) async throws {
            try await onLdkQueue { try lightningService.offlineReceivePayment().cancel(requestId: requestId) }
        }

        private func onLdkQueue<T>(_ operation: @escaping () throws -> T) async throws -> T {
            try await ServiceQueue.background(.ldk, wrapErrors: false) {
                do {
                    return try operation()
                } catch let error as NodeError {
                    throw OfflineReceiveNodeError(error) ?? error
                }
            }
        }
    }

    extension OfflineReceiveNodeStatus {
        init(_ status: LDKNode.OfflineReceiveStatus) {
            switch status {
            case .preparing: self = .preparing
            case .awaitingActivation: self = .awaitingActivation
            case .awaitingWitnesses: self = .awaitingWitnesses
            case let .ready(bolt11): self = .ready(bolt11: bolt11)
            case .expired: self = .expired
            case let .settled(outcome): self = .settled(fulfilled: outcome == .fulfilled)
            case let .failed(reason): self = .failed(reason: reason)
            }
        }
    }

    extension OfflineReceiveNodeError {
        init?(_ error: NodeError) {
            switch error {
            case .OfflineReceiveDisabled: self = .disabled
            case .OfflineReceiveUnavailable: self = .unavailable
            case .OfflineReceiveIneligible: self = .ineligible
            case .OfflineReceiveRequestNotFound: self = .requestNotFound
            case .OfflineReceiveRequestConflict: self = .requestConflict
            default: return nil
            }
        }
    }
#endif
