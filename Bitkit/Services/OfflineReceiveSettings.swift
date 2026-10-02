import Foundation

/// Node-side FFOR parameters passed to the LDK Node builder when the developer toggle is on.
/// Timing and fee values are the development defaults of the offline receive binding.
struct OfflineReceiveNodeConfiguration: Equatable {
    let settlementNodeId: String
    let witnessNodeIds: [String]
    let invoiceExpirySeconds: UInt32 = 3600
    let invoiceSafetyMarginSeconds: UInt32 = 120
    let settlementDeadlineBlocks: UInt32 = 144
    let deadlineSafetyMarginBlocks: UInt32 = 6
    let claimMarginBlocks: UInt32 = 20
    let voucherExpiryBlocks: UInt32 = 288
    let feeBaseMsat: UInt32 = 0
    let feeProportionalMillionths: UInt32 = 0
    let pollIntervalSecs: UInt64 = 5
    let witnessRetentionBlocks: UInt32 = 288
    let witnessMinimumReceipts: UInt8 = 0
}

/// Developer-only switches for the experimental offline receive provider.
/// Nothing is configured unless the build carries the local binding and the toggle is on.
enum OfflineReceiveSettings {
    static let enabledKey = "offlineReceiveExperimentalEnabled"
    static let settlementNodeIdKey = "offlineReceiveSettlementNodeId"
    static let witnessNodeIdsKey = "offlineReceiveWitnessNodeIds"

    static var isBuildAvailable: Bool {
        #if OFFLINE_RECEIVE_LOCAL_LDK
            true
        #else
            false
        #endif
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        isBuildAvailable && defaults.bool(forKey: enabledKey)
    }

    /// The settlement node defaults to the Blocktank LSP peer Bitkit already trusts for the current network.
    static func nodeConfiguration(
        defaults: UserDefaults = .standard,
        trustedPeers: [LnPeer] = Env.trustedLnPeers
    ) -> OfflineReceiveNodeConfiguration? {
        guard defaults.bool(forKey: enabledKey) else { return nil }
        let settlementNodeId = nodeIds(from: defaults.string(forKey: settlementNodeIdKey)).first ?? trustedPeers.first?.nodeId
        guard let settlementNodeId, isNodeId(settlementNodeId) else { return nil }
        let witnessNodeIds = nodeIds(from: defaults.string(forKey: witnessNodeIdsKey)).filter { $0 != settlementNodeId }
        return OfflineReceiveNodeConfiguration(settlementNodeId: settlementNodeId, witnessNodeIds: witnessNodeIds)
    }

    static func nodeIds(from text: String?) -> [String] {
        guard let text else { return [] }
        var seen = Set<String>()
        return text
            .split(whereSeparator: { $0 == "," || $0.isWhitespace || $0.isNewline })
            .map { $0.lowercased() }
            .filter { isNodeId($0) && seen.insert($0).inserted }
    }

    static func isNodeId(_ candidate: String) -> Bool {
        candidate.count == 66 &&
            (candidate.hasPrefix("02") || candidate.hasPrefix("03")) &&
            candidate.allSatisfy(\.isHexDigit)
    }
}
