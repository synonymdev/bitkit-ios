import Foundation

/// One NDEF record, decoupled from Core NFC so it can be parsed and tested without a reader session.
struct NdefRecord: Equatable, Sendable {
    let typeNameFormat: UInt8
    let type: Data
    let payload: Data
}

enum NdefPayloadError: Error, Equatable, Sendable {
    /// The tag held no record carrying text or a URI.
    case empty
    /// The tag held more than one different payment request, so the intended one is ambiguous.
    case multiplePayloads
}

/// Extracts the payment request (a URI, invoice or address) carried by an NFC tag.
///
/// Payment terminals and Android wallets that emulate a tag publish one NDEF record: either a well-known
/// URI record (`lightning:lnbc…`, `bitcoin:…?lightning=…`, `lnurlw://…`, `ethereum:…`) or a well-known
/// Text record holding the same string. The result goes to the same handling as a scanned QR code.
enum NdefPayloadParser {
    static let tnfWellKnown: UInt8 = 0x01
    static let tnfAbsoluteUri: UInt8 = 0x03

    private static let uriRecordType = Data([0x55]) // "U"
    private static let textRecordType = Data([0x54]) // "T"

    /// URI identifier codes from the NFC Forum URI Record Type Definition, indexed by code.
    static let uriPrefixes: [String] = [
        "", "http://www.", "https://www.", "http://", "https://", "tel:", "mailto:",
        "ftp://anonymous:anonymous@", "ftp://ftp.", "ftps://", "sftp://", "smb://", "nfs://", "ftp://",
        "dav://", "news:", "telnet://", "imap:", "rtsp://", "urn:", "pop:", "sip:", "sips:", "tftp:",
        "btspp://", "btl2cap://", "btgoep://", "tcpobex://", "irdaobex://", "file://", "urn:epc:id:",
        "urn:epc:tag:", "urn:epc:pat:", "urn:epc:raw:", "urn:epc:", "urn:nfc:",
    ]

    static func paymentRequest(from records: [NdefRecord]) -> Result<String, NdefPayloadError> {
        var values: [String] = []
        for record in records {
            guard let value = decode(record)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                continue
            }
            if !values.contains(value) {
                values.append(value)
            }
        }

        switch values.count {
        case 0: return .failure(.empty)
        case 1: return .success(values[0])
        default: return .failure(.multiplePayloads)
        }
    }

    static func decode(_ record: NdefRecord) -> String? {
        switch record.typeNameFormat {
        case tnfWellKnown where record.type == uriRecordType:
            return decodeUri(record.payload)
        case tnfWellKnown where record.type == textRecordType:
            return decodeText(record.payload)
        case tnfAbsoluteUri:
            return String(data: record.type, encoding: .utf8)
        default:
            return nil
        }
    }

    static func decodeUri(_ payload: Data) -> String? {
        guard let code = payload.first else { return nil }
        let prefix = Int(code) < uriPrefixes.count ? uriPrefixes[Int(code)] : ""
        guard let body = String(data: payload.dropFirst(), encoding: .utf8) else { return nil }
        return prefix + body
    }

    static func decodeText(_ payload: Data) -> String? {
        guard let status = payload.first else { return nil }
        let isUtf16 = status & 0x80 != 0
        let languageLength = Int(status & 0x3F)
        let textStart = 1 + languageLength
        guard payload.count >= textStart else { return nil }
        let text = payload.dropFirst(textStart)
        return String(data: Data(text), encoding: isUtf16 ? .utf16 : .utf8)
    }
}
