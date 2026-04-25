@testable import Bitkit
import Foundation
import XCTest

final class PublicPaykitServiceTests: XCTestCase {
    func testParseEndpointReadsSpecPayloadObject() {
        let endpoint = PublicPaykitService.parseEndpoint(
            methodId: "btc-lightning-bolt11",
            endpointData: #"{"value":"lnbc1example","min":"1000","max":"2000"}"#
        )

        XCTAssertEqual(endpoint?.methodId, .bitcoinLightningBolt11)
        XCTAssertEqual(endpoint?.value, "lnbc1example")
        XCTAssertEqual(endpoint?.min, "1000")
        XCTAssertEqual(endpoint?.max, "2000")
    }

    func testParseEndpointRejectsRawStringPayload() {
        let endpoint = PublicPaykitService.parseEndpoint(
            methodId: "btc-bitcoin-p2wpkh",
            endpointData: "bc1qexampleaddress"
        )

        XCTAssertNil(endpoint)
    }

    func testParseEndpointRejectsUnsupportedMethodId() {
        let endpoint = PublicPaykitService.parseEndpoint(
            methodId: "btc-lightning-bolt12",
            endpointData: #"{"value":"anything"}"#
        )

        XCTAssertNil(endpoint)
    }

    func testSerializePayloadWrapsValueInJsonObject() throws {
        let payload = try PublicPaykitService.serializePayload(value: "  lnbc1invoice  ")
        let json = try XCTUnwrap(payload.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: String])

        XCTAssertEqual(object["value"], "lnbc1invoice")
        XCTAssertEqual(object.count, 1)
    }

    func testOnchainMethodIdUsesAddressPrefix() {
        XCTAssertEqual(PublicPaykitService.onchainMethodId(for: "bc1pexample"), .bitcoinOnchainP2tr)
        XCTAssertEqual(PublicPaykitService.onchainMethodId(for: "tb1qexample"), .bitcoinOnchainP2wpkh)
        XCTAssertEqual(PublicPaykitService.onchainMethodId(for: "3Example"), .bitcoinOnchainP2sh)
        XCTAssertEqual(PublicPaykitService.onchainMethodId(for: "1Example"), .bitcoinOnchainP2pkh)
    }
}
