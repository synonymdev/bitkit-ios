@testable import Bitkit
import XCTest

final class NdefPayloadParserTests: XCTestCase {
    private let invoice = "lnbcrt10u1pjexample"

    func testUriRecordWithoutPrefixCodeKeepsTheFullUri() {
        let record = uriRecord(code: 0x00, "lightning:\(invoice)")
        XCTAssertEqual(NdefPayloadParser.paymentRequest(from: [record]), .success("lightning:\(invoice)"))
    }

    func testSquareRegisterUriRecordIsReadAsIs() {
        let record = uriRecord(code: 0x00, PosNfcFixtures.squareUri)
        XCTAssertEqual(record.payload.count, 0x1CA)
        XCTAssertEqual(NdefPayloadParser.paymentRequest(from: [record]), .success(PosNfcFixtures.squareUri))
    }

    func testNumoBip321UriRecordIsReadAsIs() {
        let record = uriRecord(code: 0x00, PosNfcFixtures.bip321Uri)
        XCTAssertEqual(NdefPayloadParser.paymentRequest(from: [record]), .success(PosNfcFixtures.bip321Uri))
    }

    func testUriRecordExpandsPrefixCode() {
        let record = uriRecord(code: 0x04, "example.com/lnurlp/alice")
        XCTAssertEqual(NdefPayloadParser.decode(record), "https://example.com/lnurlp/alice")
    }

    func testUnknownPrefixCodeIsTreatedAsNoPrefix() {
        let record = uriRecord(code: 0xFE, "bitcoin:bcrt1qexample")
        XCTAssertEqual(NdefPayloadParser.decode(record), "bitcoin:bcrt1qexample")
    }

    func testUtf8TextRecordSkipsLanguageCode() {
        let record = textRecord(language: "en", "  lightning:\(invoice)\n")
        XCTAssertEqual(NdefPayloadParser.paymentRequest(from: [record]), .success("lightning:\(invoice)"))
    }

    func testUtf16TextRecordIsDecoded() throws {
        let text = "bitcoin:bcrt1qexample?lightning=\(invoice)"
        var payload = Data([0x80 | 0x02])
        payload.append(contentsOf: Array("en".utf8))
        try payload.append(XCTUnwrap(text.data(using: .utf16)))
        let record = NdefRecord(typeNameFormat: NdefPayloadParser.tnfWellKnown, type: Data([0x54]), payload: payload)
        XCTAssertEqual(NdefPayloadParser.decode(record), text)
    }

    func testAbsoluteUriRecordUsesTheTypeField() {
        let uri = "ethereum:0x18503bD685aF84E6A7bC289898bAa1C3f5d8527E@42161"
        let record = NdefRecord(typeNameFormat: NdefPayloadParser.tnfAbsoluteUri, type: Data(uri.utf8), payload: Data())
        XCTAssertEqual(NdefPayloadParser.paymentRequest(from: [record]), .success(uri))
    }

    func testOtherRecordsAreIgnored() {
        let androidAppRecord = NdefRecord(
            typeNameFormat: 0x04,
            type: Data("android.com:pkg".utf8),
            payload: Data("to.bitkit".utf8)
        )
        let records = [androidAppRecord, uriRecord(code: 0x00, "lightning:\(invoice)")]
        XCTAssertEqual(NdefPayloadParser.paymentRequest(from: records), .success("lightning:\(invoice)"))
    }

    func testDuplicateRecordsCollapseToOneRequest() {
        let records = [uriRecord(code: 0x00, "lightning:\(invoice)"), textRecord(language: "en", "lightning:\(invoice)")]
        XCTAssertEqual(NdefPayloadParser.paymentRequest(from: records), .success("lightning:\(invoice)"))
    }

    func testDifferentRequestsAreRejected() {
        let records = [uriRecord(code: 0x00, "lightning:\(invoice)"), uriRecord(code: 0x00, "bitcoin:bcrt1qexample")]
        XCTAssertEqual(NdefPayloadParser.paymentRequest(from: records), .failure(.multiplePayloads))
    }

    func testEmptyTagIsRejected() {
        XCTAssertEqual(NdefPayloadParser.paymentRequest(from: []), .failure(.empty))
        XCTAssertEqual(NdefPayloadParser.paymentRequest(from: [textRecord(language: "en", "   ")]), .failure(.empty))
        XCTAssertEqual(NdefPayloadParser.paymentRequest(from: [uriRecordPayload(Data())]), .failure(.empty))
    }

    func testTruncatedTextRecordIsIgnored() {
        let record = NdefRecord(typeNameFormat: NdefPayloadParser.tnfWellKnown, type: Data([0x54]), payload: Data([0x05, 0x65]))
        XCTAssertNil(NdefPayloadParser.decode(record))
    }

    private func uriRecord(code: UInt8, _ body: String) -> NdefRecord {
        uriRecordPayload(Data([code]) + Data(body.utf8))
    }

    private func uriRecordPayload(_ payload: Data) -> NdefRecord {
        NdefRecord(typeNameFormat: NdefPayloadParser.tnfWellKnown, type: Data([0x55]), payload: payload)
    }

    private func textRecord(language: String, _ text: String) -> NdefRecord {
        var payload = Data([UInt8(language.utf8.count)])
        payload.append(contentsOf: Array(language.utf8))
        payload.append(contentsOf: Array(text.utf8))
        return NdefRecord(typeNameFormat: NdefPayloadParser.tnfWellKnown, type: Data([0x54]), payload: payload)
    }
}
