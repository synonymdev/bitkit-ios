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

    func testParseEndpointReadsPaykyLnurlMethodId() {
        let endpoint = PublicPaykitService.parseEndpoint(
            methodId: "btc-lightning-lnurl",
            endpointData: #"{"value":"lnurl1example"}"#
        )

        XCTAssertEqual(endpoint?.methodId, .bitcoinLightningLnurl)
        XCTAssertEqual(endpoint?.value, "lnurl1example")
    }

    func testParseEndpointRejectsNonSpecLegacyLnurlMethodId() {
        let endpoint = PublicPaykitService.parseEndpoint(
            methodId: "btc-lightning-lnurl-pay",
            endpointData: #"{"value":"lnurl1example"}"#
        )

        XCTAssertNil(endpoint)
    }

    func testKnownMethodIdsFollowPaymentEndpointIdentifierSpec() {
        let specPattern = #"^[a-z0-9]+-[a-z0-9]+-[a-z0-9]+$"#
        let methodIds: [PublicPaykitService.MethodId] = [
            .bitcoinLightningBolt11,
            .bitcoinLightningLnurl,
            .bitcoinOnchainP2tr,
            .bitcoinOnchainP2wpkh,
            .bitcoinOnchainP2sh,
            .bitcoinOnchainP2pkh,
        ]

        for methodId in methodIds {
            XCTAssertNotNil(methodId.rawValue.range(of: specPattern, options: .regularExpression), "\(methodId.rawValue) must be asset-rail-endpoint")
        }
    }

    func testSerializePayloadWrapsValueInJsonObject() throws {
        let payload = try PublicPaykitService.serializePayload(value: "  lnbc1invoice  ")
        let json = try XCTUnwrap(payload.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: String])

        XCTAssertEqual(object["value"], "lnbc1invoice")
        XCTAssertEqual(object.count, 1)
    }

    func testPaymentRequestCombinesOnchainAndBolt11Endpoints() {
        let request = PublicPaykitService.paymentRequest(from: [
            PublicPaykitService.Endpoint(
                methodId: .bitcoinLightningBolt11,
                value: "lnbc1invoice",
                min: nil,
                max: nil,
                rawPayload: #"{"value":"lnbc1invoice"}"#
            ),
            PublicPaykitService.Endpoint(
                methodId: .bitcoinOnchainP2wpkh,
                value: "bc1qaddress",
                min: nil,
                max: nil,
                rawPayload: #"{"value":"bc1qaddress"}"#
            ),
        ])

        XCTAssertEqual(request, "bitcoin:bc1qaddress?lightning=lnbc1invoice")
    }

    func testPaymentRequestPrefersTaprootWhenMultipleOnchainEndpointsExist() {
        let request = PublicPaykitService.paymentRequest(from: [
            PublicPaykitService.Endpoint(
                methodId: .bitcoinLightningBolt11,
                value: "lnbc1invoice",
                min: nil,
                max: nil,
                rawPayload: #"{"value":"lnbc1invoice"}"#
            ),
            PublicPaykitService.Endpoint(
                methodId: .bitcoinOnchainP2pkh,
                value: "1legacy",
                min: nil,
                max: nil,
                rawPayload: #"{"value":"1legacy"}"#
            ),
            PublicPaykitService.Endpoint(
                methodId: .bitcoinOnchainP2wpkh,
                value: "bc1qsegwit",
                min: nil,
                max: nil,
                rawPayload: #"{"value":"bc1qsegwit"}"#
            ),
            PublicPaykitService.Endpoint(
                methodId: .bitcoinOnchainP2tr,
                value: "bc1ptaproot",
                min: nil,
                max: nil,
                rawPayload: #"{"value":"bc1ptaproot"}"#
            ),
        ])

        XCTAssertEqual(request, "bitcoin:bc1ptaproot?lightning=lnbc1invoice")
    }

    func testPaymentRequestFallsBackToPreferredEndpointWhenCombinedRequestIsNotAvailable() {
        let request = PublicPaykitService.paymentRequest(from: [
            PublicPaykitService.Endpoint(
                methodId: .bitcoinLightningBolt11,
                value: "lnbc1invoice",
                min: nil,
                max: nil,
                rawPayload: #"{"value":"lnbc1invoice"}"#
            ),
        ])

        XCTAssertEqual(request, "lnbc1invoice")
    }

    func testOnchainMethodIdUsesAddressPrefix() {
        XCTAssertEqual(PublicPaykitService.onchainMethodId(for: "bc1pexample"), .bitcoinOnchainP2tr)
        XCTAssertEqual(PublicPaykitService.onchainMethodId(for: "tb1qexample"), .bitcoinOnchainP2wpkh)
        XCTAssertEqual(PublicPaykitService.onchainMethodId(for: "3Example"), .bitcoinOnchainP2sh)
        XCTAssertEqual(PublicPaykitService.onchainMethodId(for: "1Example"), .bitcoinOnchainP2pkh)
    }

    func testPaymentLaunchResultFailureMessageKeys() {
        XCTAssertNil(PublicPaykitPaymentLaunchResult.opened(paymentRequest: "bitcoin:bcrt1ptest").contactPaymentFailureMessageKey)
        XCTAssertEqual(PublicPaykitPaymentLaunchResult.noEndpoint.contactPaymentFailureMessageKey, "slashtags__error_pay_empty_msg")
        XCTAssertEqual(PublicPaykitPaymentLaunchResult.notOpened.contactPaymentFailureMessageKey, "slashtags__error_pay_not_opened_msg")
    }
}
