import BitkitCore
import Foundation

enum SeedQRCodeDecoderError: Error {
    case invalidPayload
}

enum SeedQRCodeDecoder {
    private static let compactEntropyLength = 16

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

            do {
                return try decodeCompactSeedQr(entropy: entropy)
            } catch {
                throw SeedQRCodeDecoderError.invalidPayload
            }
        }

        throw SeedQRCodeDecoderError.invalidPayload
    }

    private static func decodeStandard(_ payload: String) throws -> String? {
        do {
            return try decodeStandardSeedQr(payload: payload)
        } catch {
            return nil
        }
    }

    private static func decodeCompactEntropy(_ payload: Data) -> Data? {
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
