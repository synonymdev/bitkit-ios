import CoreBluetooth
import Foundation

/// Bitkit nearby payments over Bluetooth LE, version 1. See docs/nearby-payments.md.
///
/// The receiving phone serves its payment request from a GATT service; a paying phone reads the meta
/// characteristic for the length and then as many 512-byte data chunks as it needs.
enum NearbyProtocol {
    static let serviceUUID = CBUUID(string: "CB0E128B-1CA5-4959-94DF-A4FE588E3E98")
    static let metaUUID = CBUUID(string: "69A713E5-B0A7-42F1-8B7F-FA0BDA119C00")
    static let dataUUIDs: [CBUUID] = (1 ... chunkCount).map {
        CBUUID(string: String(format: "69A713E5-B0A7-42F1-8B7F-FA0BDA119C%02X", $0))
    }

    static let version: UInt8 = 0x01
    static let chunkSize = 512
    static let chunkCount = 8
    static let maxRequestBytes = chunkSize * chunkCount
    static let minRssi = -60

    /// The request as served, or nil when it is empty or too large to serve.
    static func encodeRequest(_ request: String) -> Data? {
        let bytes = Data(request.utf8)
        guard !bytes.isEmpty, bytes.count <= maxRequestBytes else { return nil }
        return bytes
    }

    static func meta(for request: Data) -> Data {
        Data([version, UInt8((request.count >> 8) & 0xFF), UInt8(request.count & 0xFF)])
    }

    /// Chunk `index` of `request`; empty past the end of the request.
    static func chunk(_ request: Data, index: Int) -> Data {
        let start = index * chunkSize
        guard (0 ..< chunkCount).contains(index), start < request.count else { return Data() }
        let end = min(request.count, start + chunkSize)
        return request.subdata(in: (request.startIndex + start) ..< (request.startIndex + end))
    }

    /// The request length announced by `meta`, or nil for an unknown version or bad length.
    static func requestLength(meta: Data) -> Int? {
        let bytes = [UInt8](meta)
        guard bytes.count >= 3, bytes[0] == version else { return nil }
        let length = (Int(bytes[1]) << 8) | Int(bytes[2])
        return (1 ... maxRequestBytes).contains(length) ? length : nil
    }

    static func chunks(for length: Int) -> Int {
        (length + chunkSize - 1) / chunkSize
    }

    /// Value served for a read at `offset` of a characteristic whose full value is `value`.
    static func read(_ value: Data, at offset: Int) -> Data? {
        guard (0 ... value.count).contains(offset) else { return nil }
        return value.subdata(in: (value.startIndex + offset) ..< value.endIndex)
    }

    static func decode(chunks: [Data], length: Int) -> String? {
        let bytes = chunks.reduce(Data(), +)
        guard bytes.count == length, let text = String(data: bytes, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The value served for `uuid`, or nil when it is not one of the protocol's characteristics.
    static func value(for uuid: CBUUID, request: Data) -> Data? {
        if uuid == metaUUID {
            return meta(for: request)
        }
        guard let index = dataUUIDs.firstIndex(of: uuid) else { return nil }
        return chunk(request, index: index)
    }
}

/// Turns a receive request into the URI offered to nearby phones (NFC tag or Bluetooth).
///
/// Other wallets need a scheme to recognise the request, so a bare BOLT11 invoice, offer or LNURL gets
/// `lightning:` and a bare address gets `bitcoin:`. Requests that already carry a payment scheme are
/// returned unchanged.
enum NearbyPaymentUri {
    private static let uriSchemes = ["bitcoin:", "lightning:", "ethereum:", "lnurlp:", "lnurlw:", "lnurlc:"]
    private static let lightningPrefixes = ["lnbc", "lntb", "lntbs", "lnbcrt", "lnsb", "lno1", "lnurl"]

    static func from(_ request: String?) -> String? {
        let trimmed = request?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let lowercase = trimmed.lowercased()
        if uriSchemes.contains(where: { lowercase.hasPrefix($0) }) {
            return trimmed
        }
        if lightningPrefixes.contains(where: { lowercase.hasPrefix($0) }) {
            return "lightning:\(trimmed)"
        }
        return "bitcoin:\(trimmed)"
    }
}
