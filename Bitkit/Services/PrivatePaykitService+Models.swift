import Foundation

// MARK: - State Models

extension PrivatePaykitService {
    struct PrivatePaykitState: Codable {
        var contacts: [String: ContactState]
    }

    struct ContactState: Codable {
        var cachedResolvedEndpoints: [StoredPaymentEntry] = []
        var consumedPrivatePaymentListVersion: UInt64?
        /// The automatic payment attempt that consumed the list, so only that attempt gives it back. Local to this device:
        /// the wallet backup carries the version alone.
        var consumedPrivatePaymentListOwner: String?
        var localInvoice: StoredInvoice?
        var receivedInvoicePaymentHashes: [String] = []
        var hasPublishedPrivatePaymentList = false

        var hasCacheState: Bool {
            hasPublishedPrivatePaymentList ||
                !cachedResolvedEndpoints.isEmpty ||
                consumedPrivatePaymentListVersion != nil ||
                localInvoice != nil ||
                !receivedInvoicePaymentHashes.isEmpty
        }

        var hasContactOwnedCacheState: Bool {
            hasPublishedPrivatePaymentList ||
                !cachedResolvedEndpoints.isEmpty ||
                localInvoice != nil ||
                !receivedInvoicePaymentHashes.isEmpty
        }
    }

    struct StoredPaymentEntry: Codable, Equatable {
        var methodId: String
        var endpointData: String

        init(methodId: String, endpointData: String) {
            self.methodId = methodId
            self.endpointData = endpointData
        }

        init(endpoint: PublicPaykitService.Endpoint) {
            methodId = endpoint.methodId.rawValue
            endpointData = endpoint.rawPayload
        }
    }

    struct StoredInvoice: Codable, Equatable {
        var bolt11: String
        var paymentHash: String
        var expiresAt: Double
    }

    struct Backup: Codable {
        let sdkState: String
        let consumedPrivatePaymentListVersions: [String: UInt64]
    }
}
