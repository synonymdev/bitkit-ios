import Foundation

// MARK: - State Models

extension PrivatePaykitService {
    struct PrivatePaykitState: Codable {
        var contacts: [String: ContactState]
    }

    struct ContactState: Codable {
        var cachedResolvedEndpoints: [StoredPaymentEntry] = []
        var localInvoice: StoredInvoice?
        var receivedInvoicePaymentHashes: [String] = []
        var hasPublishedPrivatePaymentList = false

        init() {}

        var hasCacheState: Bool {
            hasPublishedPrivatePaymentList ||
                !cachedResolvedEndpoints.isEmpty ||
                localInvoice != nil ||
                !receivedInvoicePaymentHashes.isEmpty
        }
    }

    struct StoredPaymentEntry: Codable {
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

    struct StoredInvoice: Codable {
        var bolt11: String
        var paymentHash: String
        var expiresAt: Double
    }
}
