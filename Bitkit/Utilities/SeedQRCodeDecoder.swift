import BitkitCore
import Foundation

enum SeedQRCodeDecoderError: Error {
    case invalidPayload
}

enum SeedQRCodeDecoder {
    private static let compactEntropyLength = 16
    private static let standardPayloadLength = 48
    private static let wordIndexLength = 4

    static func decode(_ payload: QRCodePayload) throws -> String {
        if let string = payload.string,
           let mnemonic = try decodeStandard(string)
        {
            return mnemonic
        }

        if let data = payload.data {
            if let string = String(data: data, encoding: .utf8),
               let mnemonic = try decodeStandard(string)
            {
                return mnemonic
            }

            guard let entropy = decodeCompactEntropy(data) else {
                throw SeedQRCodeDecoderError.invalidPayload
            }

            let mnemonic = try entropyToMnemonic(entropy: entropy)
            try validateMnemonic(mnemonicPhrase: mnemonic)
            return mnemonic
        }

        throw SeedQRCodeDecoderError.invalidPayload
    }

    private static func decodeStandard(_ payload: String) throws -> String? {
        guard payload.utf8.count == standardPayloadLength,
              payload.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 })
        else {
            return nil
        }

        let wordlist = getBip39Wordlist()
        let bytes = Array(payload.utf8)
        var words = [String]()
        words.reserveCapacity(standardPayloadLength / wordIndexLength)

        for offset in stride(from: 0, to: bytes.count, by: wordIndexLength) {
            guard let index = Int(String(decoding: bytes[offset ..< offset + wordIndexLength], as: UTF8.self)),
                  wordlist.indices.contains(index)
            else {
                throw SeedQRCodeDecoderError.invalidPayload
            }
            words.append(wordlist[index])
        }

        let mnemonic = words.joined(separator: " ")
        do {
            try validateMnemonic(mnemonicPhrase: mnemonic)
            return mnemonic
        } catch {
            throw SeedQRCodeDecoderError.invalidPayload
        }
    }

    private static func decodeCompactEntropy(_ payload: Data) -> Data? {
        if payload.count == compactEntropyLength {
            return payload
        }

        var reader = SeedQRBitReader(data: payload)
        guard reader.read(bitCount: 4) == 4,
              reader.read(bitCount: 8) == compactEntropyLength
        else {
            return nil
        }

        var entropy = Data()
        entropy.reserveCapacity(compactEntropyLength)
        for _ in 0 ..< compactEntropyLength {
            guard let byte = reader.read(bitCount: 8) else { return nil }
            entropy.append(UInt8(byte))
        }
        return entropy
    }
}

private struct SeedQRBitReader {
    let data: Data
    private var bitOffset = 0

    init(data: Data) {
        self.data = data
    }

    mutating func read(bitCount: Int) -> Int? {
        guard bitCount > 0, bitOffset + bitCount <= data.count * 8 else { return nil }

        var value = 0
        for _ in 0 ..< bitCount {
            let byte = data[bitOffset / 8]
            let shift = 7 - (bitOffset % 8)
            value = (value << 1) | Int((byte >> shift) & 1)
            bitOffset += 1
        }
        return value
    }
}
