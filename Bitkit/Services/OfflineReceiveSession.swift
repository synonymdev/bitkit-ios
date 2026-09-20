import Foundation
import Observation

struct PreparedOfflineInvoice {
    let bolt11: String
}

struct OfflineReceiveInvoice: Equatable {
    let bolt11: String
    let amountSats: UInt64
    let note: String
    let paymentHash: String
    let expiresAt: Date

    func canDisplay(amountSats: UInt64, note: String, now: Date = .now) -> Bool {
        self.amountSats == amountSats && self.note == note && expiresAt > now
    }
}

@MainActor
protocol OfflineReceiveProviding {
    func canReceive(amountSats: UInt64) async throws -> Bool

    /// Returns only after FFOR activation and recovery data are durably stored.
    /// Implementations must not return an ordinary Lightning invoice on failure.
    func prepareInvoice(requestId: String, amountSats: UInt64, description: String, expirySecs: UInt32) async throws -> PreparedOfflineInvoice
}

enum OfflineReceiveError: LocalizedError {
    case unavailable
    case insufficientLiquidity
    case invalidInvoice

    var errorDescription: String? {
        switch self {
        case .unavailable: t("wallet__receive_offline_unavailable")
        case .insufficientLiquidity: t("wallet__receive_offline_liquidity")
        case .invalidInvoice: t("wallet__receive_offline_failed")
        }
    }
}

struct UnavailableOfflineReceiveProvider: OfflineReceiveProviding {
    nonisolated init() {}

    func canReceive(amountSats _: UInt64) async throws -> Bool { false }

    func prepareInvoice(requestId _: String, amountSats _: UInt64, description _: String,
                        expirySecs _: UInt32) async throws -> PreparedOfflineInvoice
    {
        throw OfflineReceiveError.unavailable
    }
}

struct OfflineReceiveEligibility: Equatable, Hashable {
    let amountSats: UInt64
    let inboundCapacitySats: UInt64?
    let isNodeRunning: Bool
    let supportsLightning: Bool

    var hasLiquidity: Bool {
        guard supportsLightning, isNodeRunning, amountSats > 0, let inboundCapacitySats else { return false }
        return amountSats <= inboundCapacitySats
    }
}

@MainActor
@Observable
final class OfflineReceiveSession {
    private let provider: any OfflineReceiveProviding
    private var eligibility: OfflineReceiveEligibility?
    private var revision = UUID()
    private var preparation: Preparation?
    private(set) var isEligible = false
    private(set) var isSelected = false

    private final class Preparation {
        let requestId = UUID().uuidString
        let amountSats: UInt64
        let description: String
        let expirySecs: UInt32
        var attempted = false

        init(amountSats: UInt64, description: String, expirySecs: UInt32) {
            self.amountSats = amountSats
            self.description = description
            self.expirySecs = expirySecs
        }
    }

    init(provider: any OfflineReceiveProviding) {
        self.provider = provider
    }

    func updateEligibility(_ eligibility: OfflineReceiveEligibility) async {
        let revision = UUID()
        self.revision = revision
        let hasAttempt = preparation?.attempted == true && preparation?.amountSats == eligibility.amountSats
        if self.eligibility?.amountSats != eligibility.amountSats || !eligibility.supportsLightning || (!eligibility.hasLiquidity && !hasAttempt) {
            isSelected = false
        }
        self.eligibility = eligibility
        isEligible = false
        guard eligibility.hasLiquidity else { return }

        let supported = await (try? provider.canReceive(amountSats: eligibility.amountSats)) == true
        guard self.revision == revision, !Task.isCancelled else { return }
        isEligible = supported
        if !supported, !(preparation?.attempted == true && preparation?.amountSats == eligibility.amountSats) {
            isSelected = false
        }
    }

    func setSelected(_ selected: Bool) {
        let hasAttempt = preparation?.attempted == true && preparation?.amountSats == eligibility?.amountSats
        isSelected = selected && (isEligible || hasAttempt)
    }

    func canSelect(for eligibility: OfflineReceiveEligibility) -> Bool {
        isEligible && self.eligibility == eligibility
    }

    func reset() {
        revision = UUID()
        eligibility = nil
        isEligible = false
        isSelected = false
        preparation = nil
    }

    func hasPreparationAttempt(amountSats: UInt64, description: String) -> Bool {
        preparation?.attempted == true && preparation?.amountSats == amountSats && preparation?.description == description
    }

    func expirePreparation() {
        preparation = nil
    }

    func prepareInvoice(
        eligibility: OfflineReceiveEligibility,
        description: String,
        expirySecs: UInt32
    ) async throws -> PreparedOfflineInvoice {
        let preparation: Preparation
        if let current = self.preparation,
           current.amountSats == eligibility.amountSats,
           current.description == description,
           current.expirySecs == expirySecs
        {
            preparation = current
        } else {
            preparation = Preparation(amountSats: eligibility.amountSats, description: description, expirySecs: expirySecs)
            self.preparation = preparation
        }
        if !preparation.attempted {
            guard eligibility.hasLiquidity else { throw OfflineReceiveError.insufficientLiquidity }
            guard try await provider.canReceive(amountSats: eligibility.amountSats) else { throw OfflineReceiveError.unavailable }
        }
        try Task.checkCancellation()
        preparation.attempted = true
        let invoice = try await provider.prepareInvoice(
            requestId: preparation.requestId,
            amountSats: eligibility.amountSats,
            description: description,
            expirySecs: expirySecs
        )
        try Task.checkCancellation()
        guard !invoice.bolt11.isEmpty else { throw OfflineReceiveError.invalidInvoice }
        return invoice
    }
}
