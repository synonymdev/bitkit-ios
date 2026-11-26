import BreezSdkSpark
import CryptoKit
import Foundation

/// Sends what an ended exit left at its funding address (CPFP change, or fee funding no build spent) to savings in
/// one transaction. The funding key's `CpfpSigner` signs it, the same signer the exit's CPFP children use.
enum SparkExitLeftoverSweep {
    struct Built: Equatable {
        let txid: String
        let txHex: String
        /// What reaches savings: the swept value less the fee.
        let valueSats: UInt64
    }

    enum SweepError: Error, Equatable {
        case unsupportedAddress(String)
        case unsigned
    }

    /// Spends every given UTXO of the funding address to `destination` at `feeRateSatPerVbyte`. Nil when what is left
    /// after the fee is under the destination's dust limit.
    static func build(
        utxos: [EsploraUtxo],
        fundingAddress: String,
        destination: String,
        feeRateSatPerVbyte: UInt64,
        signer: CpfpSigner
    ) async throws -> Built? {
        guard !utxos.isEmpty else { return nil }
        let inputScript = try SparkExitAddress.scriptPubKey(fundingAddress)
        let outputScript = try SparkExitAddress.scriptPubKey(destination)
        let total = utxos.reduce(0) { $0 + $1.value }
        let fee = feeSats(inputs: utxos.count, outputScriptLength: outputScript.count, feeRateSatPerVbyte: feeRateSatPerVbyte)
        guard total > fee, total - fee >= dustLimit(outputScript) else { return nil }
        let value = total - fee

        var inputs = Data()
        inputs += varInt(utxos.count)
        for utxo in utxos {
            inputs += Data(utxo.txid.hexaBytes.reversed()) + le32(utxo.vout) + [0x00] + le32(0xFFFF_FFFD)
        }
        let outputs = varInt(1) + le64(value) + varInt(outputScript.count) + outputScript
        let version = le32(2)
        let lockTime = le32(0)

        var psbt = Data("psbt".utf8) + [0xFF]
        let unsigned = version + inputs + outputs + lockTime
        psbt += varInt(1) + [0x00] + varInt(unsigned.count) + unsigned + [0x00]
        for utxo in utxos {
            let witnessUtxo = le64(utxo.value) + varInt(inputScript.count) + inputScript
            psbt += varInt(1) + [0x01] + varInt(witnessUtxo.count) + witnessUtxo + [0x00]
        }
        psbt += [0x00]

        let signed = try await signer.signPsbt(psbtBytes: psbt)
        guard let witnesses = finalWitnesses(signed, inputs: utxos.count) else { throw SweepError.unsigned }
        let tx = version + [0x00, 0x01] + inputs + outputs + witnesses.reduce(Data(), +) + lockTime
        let hex = tx.hex
        guard let txid = SparkExitTxid.txid(hex: hex) else { throw SweepError.unsigned }
        return Built(txid: txid, txHex: hex, valueSats: value)
    }

    /// The fee for P2WPKH inputs and one output, sized for 72-byte signatures.
    static func feeSats(inputs: Int, outputScriptLength: Int, feeRateSatPerVbyte: UInt64) -> UInt64 {
        let base = 4 + 1 + 41 * inputs + 1 + 8 + 1 + outputScriptLength + 4
        let witness = 2 + 108 * inputs
        let vbytes = (4 * base + witness + 3) / 4
        return UInt64(vbytes) * feeRateSatPerVbyte
    }

    /// Bitcoin Core's dust limit at its default 3 sat/vB: 294 for P2WPKH, 330 for P2TR, 540 for P2SH, 546 for P2PKH.
    static func dustLimit(_ script: Data) -> UInt64 {
        let isWitness = script.count >= 4 && (script[script.startIndex] == 0x00 || (0x51 ... 0x60).contains(script[script.startIndex]))
        return UInt64(3 * (8 + 1 + script.count + (isWitness ? 67 : 148)))
    }

    /// Each input's `final_script_witness` (PSBT input key 0x08), already in the transaction's witness encoding.
    static func finalWitnesses(_ psbt: Data, inputs: Int) -> [Data]? {
        var reader = PsbtReader(bytes: [UInt8](psbt))
        guard reader.take(5) == Array("psbt".utf8) + [0xFF], reader.skipMap() else { return nil }
        var witnesses: [Data] = []
        for _ in 0 ..< inputs {
            guard let map = reader.readMap(), let witness = map[0x08] else { return nil }
            witnesses.append(Data(witness))
        }
        return witnesses
    }

    private static func varInt(_ value: Int) -> Data {
        switch value {
        case ..<0xFD: Data([UInt8(value)])
        case ...0xFFFF: Data([0xFD]) + le16(UInt16(value))
        default: Data([0xFE]) + le32(UInt32(value))
        }
    }

    private static func le16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func le32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func le64(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private struct PsbtReader {
        let bytes: [UInt8]
        var position = 0

        mutating func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, position + count <= bytes.count else { return nil }
            defer { position += count }
            return Array(bytes[position ..< position + count])
        }

        mutating func varInt() -> Int? {
            guard let first = take(1)?.first else { return nil }
            let width = switch first {
            case 0xFD: 2
            case 0xFE: 4
            case 0xFF: 8
            default: 0
            }
            guard width > 0 else { return Int(first) }
            guard let rest = take(width) else { return nil }
            return rest.enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        }

        /// One key-value map up to its separator, by key type; keys with data after the type are kept by type too.
        mutating func readMap() -> [UInt8: [UInt8]]? {
            var map: [UInt8: [UInt8]] = [:]
            while true {
                guard let keyLength = varInt() else { return nil }
                if keyLength == 0 {
                    return map
                }
                guard let key = take(keyLength), let valueLength = varInt(), let value = take(valueLength) else { return nil }
                map[key[0]] = value
            }
        }

        mutating func skipMap() -> Bool {
            readMap() != nil
        }
    }
}

/// The output script of a Bitcoin address: bech32 and bech32m segwit, base58 P2PKH and P2SH, on any network.
enum SparkExitAddress {
    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    static func scriptPubKey(_ address: String) throws -> Data {
        if let script = segwitScript(address) ?? base58Script(address) {
            return script
        }
        throw SparkExitLeftoverSweep.SweepError.unsupportedAddress(address)
    }

    private static func segwitScript(_ address: String) -> Data? {
        let lower = address.lowercased()
        guard lower == address || address.uppercased() == address, let separator = lower.lastIndex(of: "1") else { return nil }
        let hrp = lower[..<separator]
        guard ["bc", "tb", "bcrt"].contains(hrp) else { return nil }
        let data = lower[lower.index(after: separator)...].compactMap { charset.firstIndex(of: $0).map(UInt8.init) }
        guard data.count == lower.distance(from: lower.index(after: separator), to: lower.endIndex), data.count >= 7 else { return nil }
        let checksum = polymod(hrp.unicodeScalars.map { UInt8($0.value >> 5) } + [0] + hrp.unicodeScalars.map { UInt8($0.value & 31) } + data)
        let version = data[0]
        guard version <= 16, checksum == (version == 0 ? 1 : 0x2BC8_30A3),
              let program = convertBits(Array(data[1 ..< data.count - 6])),
              (2 ... 40).contains(program.count), version != 0 || program.count == 20 || program.count == 32
        else { return nil }
        return Data([version == 0 ? 0x00 : 0x50 + version, UInt8(program.count)] + program)
    }

    private static func base58Script(_ address: String) -> Data? {
        guard let decoded = Base58.decode(address), decoded.count == 25 else { return nil }
        let bytes = [UInt8](decoded)
        let checksum = [UInt8](Data(SHA256Twice.hash(Data(bytes[0 ..< 21]))).prefix(4))
        guard Array(bytes[21...]) == checksum else { return nil }
        let hash = Array(bytes[1 ..< 21])
        switch bytes[0] {
        case 0x00, 0x6F: return Data([0x76, 0xA9, 0x14] + hash + [0x88, 0xAC])
        case 0x05, 0xC4: return Data([0xA9, 0x14] + hash + [0x87])
        default: return nil
        }
    }

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let generator: [UInt32] = [0x3B6A_57B2, 0x2650_8E6D, 0x1EA1_19FA, 0x3D42_33DD, 0x2A14_62B3]
        var checksum: UInt32 = 1
        for value in values {
            let top = checksum >> 25
            checksum = (checksum & 0x1FFFFFF) << 5 ^ UInt32(value)
            for i in 0 ..< 5 where (top >> i) & 1 == 1 {
                checksum ^= generator[i]
            }
        }
        return checksum
    }

    /// 5-bit groups to bytes, without padding.
    private static func convertBits(_ data: [UInt8]) -> [UInt8]? {
        var accumulator = 0
        var bits = 0
        var result: [UInt8] = []
        for value in data {
            accumulator = (accumulator << 5) | Int(value)
            bits += 5
            while bits >= 8 {
                bits -= 8
                result.append(UInt8((accumulator >> bits) & 0xFF))
            }
        }
        guard bits < 5, (accumulator << (8 - bits)) & 0xFF == 0 else { return nil }
        return result
    }
}

private enum SHA256Twice {
    static func hash(_ data: Data) -> Data {
        Data(SHA256.hash(data: Data(SHA256.hash(data: data))))
    }
}
