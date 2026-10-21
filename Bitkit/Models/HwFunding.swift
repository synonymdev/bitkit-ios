import BitkitCore
import CryptoKit
import Foundation
import LDKNode

/// The default address type funds are sourced from when transferring from a hardware wallet to
/// spending. v1 funds from the native-segwit account only; multi-address-type spend is out of scope.
let hwFundingDefaultAddressType: AddressScriptType = .nativeSegwit

/// A paired hardware wallet's account used to fund a transfer, resolved from the stored account
/// xpub and the watch-only balance for that address type.
struct HwFundingAccount: Equatable {
    let xpub: String
    let addressType: AddressScriptType
    let balanceSats: UInt64

    /// bitkit-core account type for composing/watching this account.
    var accountType: AccountType {
        addressType.accountType
    }
}

/// A composed (but not yet signed) hardware-wallet funding payment, produced before prompting for
/// the on-device signature so exact fees are known up front.
struct HwFundingTransaction: Equatable {
    /// Base64-encoded PSBT ready for on-device signing.
    let psbt: String
    let miningFeeSats: UInt64
    let feeRate: Float
    /// Total value spent (payment + fee, excluding change), from the composer.
    let totalSpent: UInt64
    let satsPerVByte: UInt64
}

/// A signed (but not yet broadcast) hardware-wallet funding payment. Carries the fee metadata from
/// the composed payment so the broadcast result can be built without re-reading it.
struct HwFundingSignedTx: Equatable {
    /// Signed raw transaction hex, ready to broadcast.
    let serializedTx: String
    let miningFeeSats: UInt64
    let feeRate: Float
    let totalSpent: UInt64
}

/// The result of signing a composed funding payment on the device and broadcasting it.
struct HwFundingBroadcastResult: Equatable {
    let txId: String
    let miningFeeSats: UInt64
    let feeRate: UInt64
    let totalSpent: UInt64
}

/// Matches Android's txid calculation: hash consensus bytes without marker, flag or witness.
/// This identifies a signed candidate; it does not establish backend acceptance.
enum SignedTransactionId {
    static func fromHex(_ hex: String) throws -> String {
        func invalid() -> PaykitPaymentRequestError {
            .requestUnavailable
        }
        guard (20 ... 2_000_000).contains(hex.count), hex.count.isMultiple(of: 2) else { throw invalid() }
        let chars = Array(hex.utf8)
        var bytes = [UInt8]()
        for index in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(decoding: chars[index ... index + 1], as: UTF8.self), radix: 16) else { throw invalid() }
            bytes.append(byte)
        }
        var offset = 4
        func skip(_ length: Int) throws {
            guard length >= 0, length <= bytes.count - offset else { throw invalid() }
            offset += length
        }
        func compactSize() throws -> Int {
            guard offset < bytes.count else { throw invalid() }
            let prefix = bytes[offset]
            offset += 1
            if prefix < 253 {
                return Int(prefix)
            }
            let length = prefix == 253 ? 2 : prefix == 254 ? 4 : 8
            guard length <= bytes.count - offset else { throw invalid() }
            var value: UInt64 = 0
            for index in 0 ..< length {
                value |= UInt64(bytes[offset]) << (8 * index)
                offset += 1
            }
            guard value <= UInt64(Int.max) else { throw invalid() }
            return Int(value)
        }
        let hasWitness = bytes[offset] == 0
        if hasWitness {
            guard bytes[offset + 1] == 1 else { throw invalid() }
            try skip(2)
        }
        let baseStart = offset
        let inputCount = try compactSize()
        guard inputCount > 0, inputCount <= bytes.count / 41 else { throw invalid() }
        for _ in 0 ..< inputCount {
            try skip(36)
            try skip(compactSize())
            try skip(4)
        }
        let outputCount = try compactSize()
        guard outputCount > 0, outputCount <= bytes.count / 9 else { throw invalid() }
        for _ in 0 ..< outputCount {
            try skip(8)
            try skip(compactSize())
        }
        let baseEnd = offset
        if hasWitness {
            for _ in 0 ..< inputCount {
                let count = try compactSize()
                guard count <= bytes.count - offset else { throw invalid() }
                for _ in 0 ..< count {
                    try skip(compactSize())
                }
            }
        }
        let lockTimeStart = offset
        try skip(4)
        guard offset == bytes.count else { throw invalid() }
        let canonical = Data(bytes[0 ..< 4] + bytes[baseStart ..< baseEnd] + bytes[lockTimeStart ..< offset])
        return SHA256.hash(data: Data(SHA256.hash(data: canonical))).reversed().map { String(format: "%02x", $0) }.joined()
    }
}
