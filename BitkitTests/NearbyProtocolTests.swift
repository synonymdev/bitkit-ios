@testable import Bitkit
import CoreBluetooth
import XCTest

final class NearbyProtocolTests: XCTestCase {
    func testUuidsMatchTheSharedSpec() {
        XCTAssertEqual(NearbyProtocol.serviceUUID.uuidString, "CB0E128B-1CA5-4959-94DF-A4FE588E3E98")
        XCTAssertEqual(NearbyProtocol.metaUUID.uuidString, "69A713E5-B0A7-42F1-8B7F-FA0BDA119C00")
        XCTAssertEqual(
            NearbyProtocol.dataUUIDs.map(\.uuidString),
            (1 ... 8).map { String(format: "69A713E5-B0A7-42F1-8B7F-FA0BDA119C%02X", $0) }
        )
        XCTAssertEqual(NearbyProtocol.dataUUIDs.last?.uuidString, "69A713E5-B0A7-42F1-8B7F-FA0BDA119C08")
        XCTAssertEqual(NearbyProtocol.minRssi, -60)
        XCTAssertEqual(NearbyProtocol.maxRequestBytes, 4096)
    }

    func testMetaIsVersionThenBigEndianLength() {
        XCTAssertEqual([UInt8](NearbyProtocol.meta(for: Data(repeating: 0x61, count: 5))), [0x01, 0x00, 0x05])
        XCTAssertEqual([UInt8](NearbyProtocol.meta(for: Data(repeating: 0x61, count: 4096))), [0x01, 0x10, 0x00])
        XCTAssertEqual([UInt8](NearbyProtocol.meta(for: Data(repeating: 0x61, count: 513))), [0x01, 0x02, 0x01])
    }

    func testRequestLengthRejectsUnknownVersionAndBadLengths() {
        XCTAssertEqual(NearbyProtocol.requestLength(meta: Data([0x01, 0x02, 0x01])), 513)
        XCTAssertNil(NearbyProtocol.requestLength(meta: Data([0x02, 0x00, 0x05])))
        XCTAssertNil(NearbyProtocol.requestLength(meta: Data([0x01, 0x00, 0x00])))
        XCTAssertNil(NearbyProtocol.requestLength(meta: Data([0x01, 0x10, 0x01])))
        XCTAssertNil(NearbyProtocol.requestLength(meta: Data([0x01, 0x00])))
    }

    func testEncodeRejectsEmptyAndOversizedRequests() {
        XCTAssertNil(NearbyProtocol.encodeRequest(""))
        XCTAssertNil(NearbyProtocol.encodeRequest(String(repeating: "a", count: 4097)))
        XCTAssertEqual(NearbyProtocol.encodeRequest(String(repeating: "a", count: 4096))?.count, 4096)
    }

    func testChunksSplitAt512Bytes() {
        let request = Data((0 ..< 1100).map { UInt8($0 % 251) })
        XCTAssertEqual(NearbyProtocol.chunks(for: request.count), 3)
        XCTAssertEqual(NearbyProtocol.chunk(request, index: 0), request.subdata(in: 0 ..< 512))
        XCTAssertEqual(NearbyProtocol.chunk(request, index: 1), request.subdata(in: 512 ..< 1024))
        XCTAssertEqual(NearbyProtocol.chunk(request, index: 2), request.subdata(in: 1024 ..< 1100))
        XCTAssertEqual(NearbyProtocol.chunk(request, index: 3), Data())
        XCTAssertEqual(NearbyProtocol.chunk(request, index: 8), Data())
        XCTAssertEqual(NearbyProtocol.chunks(for: 512), 1)
        XCTAssertEqual(NearbyProtocol.chunks(for: 4096), 8)
    }

    func testRoundTripThroughMetaAndChunks() throws {
        let uri = "lightning:lnbcrt" + String(repeating: "q", count: 1500)
        let request = try XCTUnwrap(NearbyProtocol.encodeRequest(uri))
        let length = try XCTUnwrap(NearbyProtocol.requestLength(meta: NearbyProtocol.meta(for: request)))
        let chunks = (0 ..< NearbyProtocol.chunks(for: length)).map { NearbyProtocol.chunk(request, index: $0) }
        XCTAssertEqual(NearbyProtocol.decode(chunks: chunks, length: length), uri)
    }

    func testDecodeRejectsLengthMismatch() {
        XCTAssertNil(NearbyProtocol.decode(chunks: [Data("abc".utf8)], length: 4))
    }

    func testReadsHonourTheAttOffset() {
        let value = Data([1, 2, 3, 4])
        XCTAssertEqual(NearbyProtocol.read(value, at: 0), value)
        XCTAssertEqual(NearbyProtocol.read(value, at: 3), Data([4]))
        XCTAssertEqual(NearbyProtocol.read(value, at: 4), Data())
        XCTAssertNil(NearbyProtocol.read(value, at: 5))
        XCTAssertNil(NearbyProtocol.read(value, at: -1))
    }

    func testValueForCharacteristic() {
        let request = Data(repeating: 0x62, count: 600)
        XCTAssertEqual(NearbyProtocol.value(for: NearbyProtocol.metaUUID, request: request), Data([0x01, 0x02, 0x58]))
        XCTAssertEqual(NearbyProtocol.value(for: NearbyProtocol.dataUUIDs[1], request: request)?.count, 88)
        XCTAssertEqual(NearbyProtocol.value(for: NearbyProtocol.dataUUIDs[7], request: request), Data())
        XCTAssertNil(NearbyProtocol.value(for: NearbyProtocol.serviceUUID, request: request))
    }

    func testPaymentUriAddsMissingSchemes() {
        XCTAssertEqual(NearbyPaymentUri.from("lnbcrt10u1pjexample"), "lightning:lnbcrt10u1pjexample")
        XCTAssertEqual(NearbyPaymentUri.from("LNBC10U1PJEXAMPLE"), "lightning:LNBC10U1PJEXAMPLE")
        XCTAssertEqual(NearbyPaymentUri.from("lno1qexample"), "lightning:lno1qexample")
        XCTAssertEqual(NearbyPaymentUri.from("LNURL1DP68GURN8GHJ7"), "lightning:LNURL1DP68GURN8GHJ7")
        XCTAssertEqual(NearbyPaymentUri.from("bcrt1qexample"), "bitcoin:bcrt1qexample")
        XCTAssertEqual(NearbyPaymentUri.from("  bitcoin:bcrt1q?lightning=lnbcrt1 "), "bitcoin:bcrt1q?lightning=lnbcrt1")
        XCTAssertEqual(NearbyPaymentUri.from("ethereum:0xabc@42161"), "ethereum:0xabc@42161")
        XCTAssertEqual(NearbyPaymentUri.from("LIGHTNING:LNBC1"), "LIGHTNING:LNBC1")
        XCTAssertEqual(NearbyPaymentUri.from("lnurlw://example.com/w"), "lnurlw://example.com/w")
        XCTAssertNil(NearbyPaymentUri.from("  "))
        XCTAssertNil(NearbyPaymentUri.from(nil))
    }

    func testScannerEligibilityAndDebounce() {
        XCTAssertTrue(NearbyPaymentScanner.isEligible(rssi: -60))
        XCTAssertTrue(NearbyPaymentScanner.isEligible(rssi: -40))
        XCTAssertFalse(NearbyPaymentScanner.isEligible(rssi: -61))
        XCTAssertFalse(NearbyPaymentScanner.isEligible(rssi: 127))
        let now = Date()
        XCTAssertFalse(NearbyPaymentScanner.isDebounced(nil, now: now))
        XCTAssertTrue(NearbyPaymentScanner.isDebounced(now.addingTimeInterval(-9.9), now: now))
        XCTAssertFalse(NearbyPaymentScanner.isDebounced(now.addingTimeInterval(-10), now: now))
    }

    @MainActor
    func testAdvertiserServesTheRequestEachCentralStartedReading() throws {
        let advertiser = NearbyPaymentAdvertiser(authorization: { .allowedAlways })
        let first = UUID()
        let second = UUID()
        let original = "lightning:lnbcrt" + String(repeating: "a", count: 700)
        advertiser.setServedRequestForTesting(original)
        XCTAssertNotNil(advertiser.servedRequest(for: first, characteristic: NearbyProtocol.metaUUID))

        advertiser.setServedRequestForTesting("bitcoin:bcrt1qnew")

        let firstRequest = try XCTUnwrap(advertiser.servedRequest(for: first, characteristic: NearbyProtocol.dataUUIDs[1]))
        XCTAssertEqual(firstRequest, Data(original.utf8))
        let secondMeta = try XCTUnwrap(advertiser.servedRequest(for: second, characteristic: NearbyProtocol.metaUUID))
        XCTAssertEqual(secondMeta, Data("bitcoin:bcrt1qnew".utf8))

        advertiser.stop()
        XCTAssertNil(advertiser.servedRequest(for: first, characteristic: NearbyProtocol.dataUUIDs[0]))
    }

    @MainActor
    func testAdvertiserDoesNotStartWithoutBluetoothPermission() {
        for authorization in [CBManagerAuthorization.notDetermined, .denied, .restricted] {
            let advertiser = NearbyPaymentAdvertiser(authorization: { authorization })
            XCTAssertFalse(advertiser.canAdvertise)
            advertiser.start(request: "bitcoin:bcrt1qexample")
            XCTAssertFalse(advertiser.isAdvertising)
            XCTAssertNil(advertiser.servedRequest(for: UUID(), characteristic: NearbyProtocol.metaUUID))
        }
    }

    func testScannerStatusTextBySources() {
        XCTAssertEqual(ScannerSources(nfc: true, bluetooth: true).statusKey, "other__scan_status_qr_nfc_bluetooth")
        XCTAssertEqual(ScannerSources(nfc: true, bluetooth: false).statusKey, "other__scan_status_qr_nfc")
        XCTAssertEqual(ScannerSources(nfc: false, bluetooth: true).statusKey, "other__scan_status_qr_bluetooth")
        XCTAssertEqual(ScannerSources(nfc: false, bluetooth: false).statusKey, "other__scan_status_qr")
    }
}
