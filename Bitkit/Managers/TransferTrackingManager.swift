import Combine
import Foundation

/// Observable manager for transfer tracking state that can be used in SwiftUI views
/// Note: This is different from TransferViewModel which handles the transfer UI flow
@MainActor
class TransferTrackingManager: ObservableObject {
    private let service: TransferService

    // Published state
    @Published var activeTransfers: [Transfer] = []
    @Published var isLoading: Bool = false
    @Published var error: Error?

    init(service: TransferService) {
        self.service = service
    }

    /// Load active transfers
    @MainActor
    func loadActiveTransfers() async {
        isLoading = true
        defer { isLoading = false }

        do {
            activeTransfers = try service.getActiveTransfers()
            error = nil
        } catch {
            self.error = error
            Logger.error("Failed to load active transfers", context: error.localizedDescription)
        }
    }

    /// Create a new transfer
    @MainActor
    func createTransfer(
        type: TransferType,
        amountSats: UInt64,
        channelId: String? = nil,
        fundingTxId: String? = nil,
        lspOrderId: String? = nil
    ) async throws -> String {
        isLoading = true
        defer { isLoading = false }

        do {
            let id = try await service.createTransfer(
                type: type,
                amountSats: amountSats,
                channelId: channelId,
                fundingTxId: fundingTxId,
                lspOrderId: lspOrderId
            )
            await loadActiveTransfers() // Refresh list
            error = nil
            return id
        } catch {
            self.error = error
            throw error
        }
    }

    /// Mark a transfer as settled
    @MainActor
    func markSettled(id: String) async throws {
        isLoading = true
        defer { isLoading = false }

        do {
            try await service.markSettled(id: id)
            await loadActiveTransfers() // Refresh list
            error = nil
        } catch {
            self.error = error
            throw error
        }
    }

    /// Sync all active transfer states
    @MainActor
    func syncTransferStates() async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await service.syncTransferStates()
            await loadActiveTransfers() // Refresh list
            error = nil
        } catch {
            self.error = error
            Logger.error("Failed to sync transfer states", context: error.localizedDescription)
        }
    }

    /// Get transfers by type
    func transfers(ofType type: TransferType) -> [Transfer] {
        return activeTransfers.filter { $0.type == type }
    }

    /// Get transfers to spending
    func transfersToSpending() -> [Transfer] {
        return activeTransfers.filter { $0.type.isToSpending() }
    }

    /// Get transfers to savings
    func transfersToSavings() -> [Transfer] {
        return activeTransfers.filter { $0.type.isToSavings() }
    }
}
