import LDKNode

extension LDKNode.TransactionDetails {
    /// The weight of this signed transaction as serialized, from its hex scripts and witness items.
    var weight: UInt64 {
        let inputBytes = inputs.reduce(UInt64(0)) { $0 + outpointAndSequenceBytes + serializedSize(hex: $1.scriptsig) }
        let outputBytes = outputs.reduce(UInt64(0)) { $0 + outputValueBytes + serializedSize(hex: $1.scriptpubkey) }
        let baseBytes = versionAndLockTimeBytes + compactSize(UInt64(inputs.count)) + inputBytes
            + compactSize(UInt64(outputs.count)) + outputBytes
        guard inputs.contains(where: { !$0.witness.isEmpty }) else { return baseBytes * witnessScaleFactor }

        let witnessBytes = inputs.reduce(UInt64(0)) { total, input in
            total + compactSize(UInt64(input.witness.count)) + input.witness.reduce(UInt64(0)) { $0 + serializedSize(hex: $1) }
        }
        return baseBytes * witnessScaleFactor + segwitMarkerAndFlagWeight + witnessBytes
    }

    /// The virtual size of this signed transaction, rounded up.
    var vsize: UInt64 {
        divideRoundingUp(weight, by: witnessScaleFactor)
    }

    /// The rate `feeSats` pays on this signed transaction, per virtual byte and rounded up.
    func feeRate(paying feeSats: UInt64) -> UInt64 {
        divideRoundingUp(feeSats, by: vsize)
    }
}

private let versionAndLockTimeBytes: UInt64 = 8
private let outpointAndSequenceBytes: UInt64 = 40
private let outputValueBytes: UInt64 = 8
private let segwitMarkerAndFlagWeight: UInt64 = 2
private let witnessScaleFactor: UInt64 = 4

private func divideRoundingUp(_ dividend: UInt64, by divisor: UInt64) -> UInt64 {
    dividend / divisor + (dividend.isMultiple(of: divisor) ? 0 : 1)
}

private func serializedSize(hex: String) -> UInt64 {
    let bytes = UInt64(hex.utf8.count / 2)
    return compactSize(bytes) + bytes
}

private func compactSize(_ value: UInt64) -> UInt64 {
    switch value {
    case 0 ... 0xFC: 1
    case 0xFD ... 0xFFFF: 3
    case 0x10000 ... 0xFFFF_FFFF: 5
    default: 9
    }
}
