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
            endpoint(.bitcoinLightningBolt11, value: "lnbc1invoice"),
            endpoint(.bitcoinOnchainP2wpkh, value: "bc1qaddress"),
        ])

        XCTAssertEqual(request, "bitcoin:bc1qaddress?lightning=lnbc1invoice")
    }

    func testPaymentRequestPercentEncodesLightningParameter() {
        let request = PublicPaykitService.paymentRequest(from: [
            endpoint(.bitcoinLightningBolt11, value: "lnbc1invoice?amount=1&label=test"),
            endpoint(.bitcoinOnchainP2wpkh, value: "bc1qaddress"),
        ])

        XCTAssertEqual(request, "bitcoin:bc1qaddress?lightning=lnbc1invoice%3Famount%3D1%26label%3Dtest")
    }

    func testPaymentRequestPrefersTaprootWhenMultipleOnchainEndpointsExist() {
        let request = PublicPaykitService.paymentRequest(from: [
            endpoint(.bitcoinLightningBolt11, value: "lnbc1invoice"),
            endpoint(.bitcoinOnchainP2pkh, value: "1legacy"),
            endpoint(.bitcoinOnchainP2wpkh, value: "bc1qsegwit"),
            endpoint(.bitcoinOnchainP2tr, value: "bc1ptaproot"),
        ])

        XCTAssertEqual(request, "bitcoin:bc1ptaproot?lightning=lnbc1invoice")
    }

    func testPaymentRequestFallsBackToPreferredEndpointWhenCombinedRequestIsNotAvailable() {
        let request = PublicPaykitService.paymentRequest(from: [
            endpoint(.bitcoinLightningBolt11, value: "lnbc1invoice"),
        ])

        XCTAssertEqual(request, "lnbc1invoice")
    }

    func testPaymentRequestFallsBackToLnurlOnlyEndpoint() {
        let request = PublicPaykitService.paymentRequest(from: [
            endpoint(.bitcoinLightningLnurl, value: "lnurl1example"),
        ])

        XCTAssertEqual(request, "lnurl1example")
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

    func testPayableEndpointsFiltersInvalidDecodedEndpoints() async {
        let payable = await PublicPaykitService.payableEndpoints(from: [
            endpoint(.bitcoinLightningBolt11, value: "not-a-bolt11"),
            endpoint(.bitcoinOnchainP2tr, value: "not-an-address"),
        ])

        XCTAssertTrue(payable.isEmpty)
    }

    func testMethodIdsToRemoveWhenUnpublishingOnlyIncludesBitkitManagedEndpoints() {
        let methodIds = PublicPaykitService.methodIdsToRemoveWhenUnpublishing(existingMethodIds: [
            .bitcoinLightningBolt11,
            .bitcoinLightningLnurl,
            .bitcoinOnchainP2tr,
        ])

        XCTAssertEqual(methodIds, [.bitcoinLightningBolt11, .bitcoinOnchainP2tr])
    }

    func testPublishedEndpointSyncPlanRemovesStalePublishedMethods() {
        let desired = [
            endpoint(.bitcoinLightningBolt11, value: "lnbc1invoice"),
            endpoint(.bitcoinOnchainP2tr, value: "bc1ptaproot"),
        ]

        let plan = PublicPaykitService.publishedEndpointSyncPlan(
            existingEndpoints: [
                .bitcoinLightningBolt11: #"{"value":"oldinvoice"}"#,
                .bitcoinOnchainP2wpkh: #"{"value":"bc1qsegwit"}"#,
                .bitcoinOnchainP2sh: #"{"value":"3nested"}"#,
            ],
            desiredEndpoints: desired
        )

        XCTAssertEqual(plan.endpointsToSet, desired)
        XCTAssertEqual(plan.methodIdsToRemove, [.bitcoinOnchainP2wpkh, .bitcoinOnchainP2sh])
    }

    func testPublishedEndpointSyncPlanSkipsUnchangedPublishedPayloads() {
        let bolt11 = endpoint(.bitcoinLightningBolt11, value: "lnbc1invoice")
        let taproot = endpoint(.bitcoinOnchainP2tr, value: "bc1ptaproot")

        let plan = PublicPaykitService.publishedEndpointSyncPlan(
            existingEndpoints: [
                .bitcoinLightningBolt11: bolt11.rawPayload,
                .bitcoinOnchainP2tr: #"{"value":"oldtaproot"}"#,
            ],
            desiredEndpoints: [bolt11, taproot]
        )

        XCTAssertEqual(plan.endpointsToSet, [taproot])
        XCTAssertTrue(plan.methodIdsToRemove.isEmpty)
    }

    func testPublishedEndpointSyncPlanPreservesExternallyOwnedLnurlEndpoint() {
        let bolt11 = endpoint(.bitcoinLightningBolt11, value: "lnbc1invoice")

        let plan = PublicPaykitService.publishedEndpointSyncPlan(
            existingEndpoints: [
                .bitcoinLightningLnurl: #"{"value":"lnurl1external"}"#,
            ],
            desiredEndpoints: [bolt11]
        )

        XCTAssertEqual(plan.endpointsToSet, [bolt11])
        XCTAssertTrue(plan.methodIdsToRemove.isEmpty)
    }

    private func endpoint(_ methodId: PublicPaykitService.MethodId, value: String) -> PublicPaykitService.Endpoint {
        PublicPaykitService.Endpoint(
            methodId: methodId,
            value: value,
            min: nil,
            max: nil,
            rawPayload: #"{"value":"\#(value)"}"#
        )
    }
}
