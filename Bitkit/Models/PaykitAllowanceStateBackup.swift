import Foundation

/// The allowance states of a wallet backup by identity. An entry this version can't read is dropped instead of failing the
/// rest of the wallet backup it travels in.
struct PaykitAllowanceStateBackups: Codable {
    let byIdentity: [String: PaykitAllowanceStateBackup]

    init(_ byIdentity: [String: PaykitAllowanceStateBackup]) {
        self.byIdentity = byIdentity
    }

    init(from decoder: Decoder) throws {
        let entries = (try? decoder.singleValueContainer().decode([String: Lenient].self)) ?? [:]
        byIdentity = entries.compactMapValues(\.value)
        if byIdentity.count != entries.count {
            Logger.warn("Skipped \(entries.count - byIdentity.count) unreadable allowance states in a backup", context: "PaykitAllowance")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(byIdentity)
    }

    private struct Lenient: Decodable {
        let value: PaykitAllowanceStateBackup?

        init(from decoder: Decoder) throws {
            value = try? PaykitAllowanceStateBackup(from: decoder)
        }
    }
}

/// One identity's local allowance state in the wallet backup, in the format both apps read: the USD labels of each
/// grant and the attempt journal restart recovery verifies from. Timestamps are RFC 3339, USD amounts decimal strings.
struct PaykitAllowanceStateBackup: Codable {
    struct Limits: Codable {
        let perPaymentUsd: String
        let monthlyUsd: String
        let perPaymentSats: UInt64
        let monthlySats: UInt64
    }

    struct Group: Codable {
        let id: String
        let counterparty: String
        let limits: Limits
        let allowanceIds: [String]
        let createdAt: String
    }

    struct JournalEntry: Codable {
        let attemptId: String
        let isAutomatic: Bool
        let requestId: PaykitPaymentStateBackup.RequestID
        let allowanceId: String?
        let amountSats: UInt64
        let paymentEndpointIdentifier: String
        let paymentHash: String?
        let onchainAddress: String?
        let transactionId: String?
        let stage: PaykitAllowanceLocalState.Stage
        let createdAt: String
        let paymentListVersion: UInt64?
        let previousPaymentListVersion: UInt64?

        /// Android requires every key, so an absent optional is written as null rather than left out.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(attemptId, forKey: .attemptId)
            try container.encode(isAutomatic, forKey: .isAutomatic)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(allowanceId, forKey: .allowanceId)
            try container.encode(amountSats, forKey: .amountSats)
            try container.encode(paymentEndpointIdentifier, forKey: .paymentEndpointIdentifier)
            try container.encode(paymentHash, forKey: .paymentHash)
            try container.encode(onchainAddress, forKey: .onchainAddress)
            try container.encode(transactionId, forKey: .transactionId)
            try container.encode(stage, forKey: .stage)
            try container.encode(createdAt, forKey: .createdAt)
            try container.encode(paymentListVersion, forKey: .paymentListVersion)
            try container.encode(previousPaymentListVersion, forKey: .previousPaymentListVersion)
        }
    }

    let groups: [Group]
    let journal: [JournalEntry]
    let presentedProposalIds: Set<String>
    let unannouncedOfferIds: Set<String>
    let notifiedRequestIds: Set<String>
    let lastTrustedTime: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(groups, forKey: .groups)
        try container.encode(journal, forKey: .journal)
        try container.encode(presentedProposalIds, forKey: .presentedProposalIds)
        try container.encode(unannouncedOfferIds, forKey: .unannouncedOfferIds)
        try container.encode(notifiedRequestIds, forKey: .notifiedRequestIds)
        try container.encode(lastTrustedTime, forKey: .lastTrustedTime)
    }

    init(_ state: PaykitAllowanceLocalState) {
        groups = state.groups.map { group in
            Group(
                id: group.id,
                counterparty: group.counterparty,
                limits: Limits(
                    perPaymentUsd: "\(group.limits.perPaymentUsd)",
                    monthlyUsd: "\(group.limits.monthlyUsd)",
                    perPaymentSats: group.limits.perPaymentSats,
                    monthlySats: group.limits.monthlySats
                ),
                allowanceIds: group.allowanceIds,
                createdAt: PaykitAllowanceTime.format(group.createdAt)
            )
        }
        journal = state.journal.map { entry in
            JournalEntry(
                attemptId: entry.attemptId,
                isAutomatic: entry.isAutomatic,
                requestId: PaykitPaymentStateBackup.RequestID(entry.requestId, billingPeriod: nil),
                allowanceId: entry.allowanceId,
                amountSats: entry.amountSats,
                paymentEndpointIdentifier: entry.paymentEndpointIdentifier,
                paymentHash: entry.paymentHash,
                onchainAddress: entry.onchainAddress,
                transactionId: entry.transactionId,
                stage: entry.stage,
                createdAt: PaykitAllowanceTime.format(entry.createdAt),
                paymentListVersion: entry.paymentListVersion,
                previousPaymentListVersion: entry.previousPaymentListVersion
            )
        }
        presentedProposalIds = state.presentedProposalIds
        unannouncedOfferIds = state.unannouncedOfferIds
        notifiedRequestIds = state.notifiedRequestIds
        lastTrustedTime = state.lastTrustedTime.map(PaykitAllowanceTime.format)
    }

    func restored() throws -> PaykitAllowanceLocalState {
        try PaykitAllowanceLocalState(
            groups: groups.map { group in
                guard let perPaymentUsd = Decimal(string: group.limits.perPaymentUsd, locale: Locale(identifier: "en_US_POSIX")),
                      let monthlyUsd = Decimal(string: group.limits.monthlyUsd, locale: Locale(identifier: "en_US_POSIX"))
                else { throw Self.invalidBackup("Invalid allowance limits") }
                return try PaykitAllowanceLocalState.Group(
                    id: group.id,
                    counterparty: group.counterparty,
                    limits: PaykitAllowanceLimits(
                        perPaymentUsd: perPaymentUsd,
                        monthlyUsd: monthlyUsd,
                        perPaymentSats: group.limits.perPaymentSats,
                        monthlySats: group.limits.monthlySats
                    ),
                    allowanceIds: group.allowanceIds,
                    createdAt: Self.date(group.createdAt)
                )
            },
            journal: journal.map { entry in
                try PaykitAllowanceLocalState.JournalEntry(
                    attemptId: entry.attemptId,
                    isAutomatic: entry.isAutomatic,
                    requestId: entry.requestId.restored(billingPeriod: nil),
                    allowanceId: entry.allowanceId,
                    amountSats: entry.amountSats,
                    paymentEndpointIdentifier: entry.paymentEndpointIdentifier,
                    paymentHash: entry.paymentHash,
                    onchainAddress: entry.onchainAddress,
                    transactionId: entry.transactionId,
                    stage: entry.stage,
                    createdAt: Self.date(entry.createdAt),
                    paymentListVersion: entry.paymentListVersion,
                    previousPaymentListVersion: entry.previousPaymentListVersion
                )
            },
            presentedProposalIds: presentedProposalIds,
            unannouncedOfferIds: unannouncedOfferIds,
            notifiedRequestIds: notifiedRequestIds,
            lastTrustedTime: lastTrustedTime.map(Self.date)
        )
    }

    private static func date(_ value: String) throws -> Date {
        guard let date = PaykitAllowanceTime.parse(value) else { throw invalidBackup("Invalid allowance timestamp") }
        return date
    }

    private static func invalidBackup(_ message: String) -> NSError {
        NSError(domain: "BackupService", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
