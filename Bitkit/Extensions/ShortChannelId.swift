import Foundation

extension UInt64 {
    /// Decodes a BOLT short channel id into Core Lightning `block x tx x output` form
    /// (e.g. `777477x916x0`): block height in the high 24 bits, transaction index in
    /// the next 24, funding output index in the low 16.
    var formattedAsShortChannelId: String {
        let blockHeight = self >> 40
        let txIndex = (self >> 16) & 0xFFFFFF
        let outputIndex = self & 0xFFFF
        return "\(blockHeight)x\(txIndex)x\(outputIndex)"
    }
}

/// Whether the string is a Core Lightning `block x tx x output` short channel id (e.g. `792906x599x1`):
/// exactly three non-empty, all-digit components separated by `x`.
private func isClnShortChannelId(_ value: String) -> Bool {
    let parts = value.split(separator: "x", omittingEmptySubsequences: false)
    return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
}

/// Resolves the short channel id to display, formatted as `block x tx x output`. Uses the channel's
/// own scid (open channels, a numeric BOLT scid) and, for closed channels which carry none, the scid
/// from the confidently-linked Blocktank order. Blocktank delivers it already in `block x tx x output`
/// form, so an `x`-formatted value is kept as-is and only a numeric value is decoded. Nil when unavailable.
func resolveDisplayShortChannelId(channelScid: UInt64?, linkedOrderScid: String?) -> String? {
    if let channelScid {
        return channelScid.formattedAsShortChannelId
    }

    guard let orderScid = linkedOrderScid, !orderScid.isEmpty else { return nil }

    if let numeric = UInt64(orderScid) {
        return numeric.formattedAsShortChannelId
    }

    return isClnShortChannelId(orderScid) ? orderScid : nil
}
