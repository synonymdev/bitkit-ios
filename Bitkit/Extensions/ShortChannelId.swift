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
