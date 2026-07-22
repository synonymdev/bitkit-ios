@testable import Bitkit
import Foundation
import LDKNode
import XCTest

final class PublicPaykitServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearPaykitDefaults()
    }

    override func tearDown() {
        clearPaykitDefaults()
        super.tearDown()
    }

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

    func testParseEndpointReadsNetworkSpecificOnchainMethodIds() {
        XCTAssertEqual(
            PublicPaykitService.parseEndpoint(
                methodId: "btc-testnet-p2wpkh",
                endpointData: #"{"value":"tb1qexample"}"#
            )?.methodId,
            .testnetOnchainP2wpkh
        )
        XCTAssertEqual(
            PublicPaykitService.parseEndpoint(
                methodId: "btc-regtest-p2tr",
                endpointData: #"{"value":"bcrt1pexample"}"#
            )?.methodId,
            .regtestOnchainP2tr
        )
    }

    func testParseEndpointRejectsUnsupportedLnurlMethodId() {
        let endpoint = PublicPaykitService.parseEndpoint(
            methodId: "btc-lightning-lnurl-pay",
            endpointData: #"{"value":"lnurl1example"}"#
        )

        XCTAssertNil(endpoint)
    }

    func testKnownMethodIdsFollowPaymentEndpointIdentifierSpec() {
        let specPattern = #"^[a-z0-9]+-[a-z0-9]+-[a-z0-9]+$"#

        for methodId in PublicPaykitService.MethodId.allCases {
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

    func testOnchainMethodIdUsesAddressPrefixAndNetwork() {
        XCTAssertEqual(PublicPaykitService.onchainMethodId(for: "bc1pexample", network: .bitcoin), .bitcoinOnchainP2tr)
        XCTAssertEqual(PublicPaykitService.onchainMethodId(for: "tb1qexample", network: .testnet), .testnetOnchainP2wpkh)
        XCTAssertEqual(PublicPaykitService.onchainMethodId(for: "bcrt1qexample", network: .regtest), .regtestOnchainP2wpkh)
        XCTAssertEqual(PublicPaykitService.onchainMethodId(for: "3Example", network: .bitcoin), .bitcoinOnchainP2sh)
        XCTAssertEqual(PublicPaykitService.onchainMethodId(for: "2Example", network: .regtest), .regtestOnchainP2sh)
        XCTAssertEqual(PublicPaykitService.onchainMethodId(for: "1Example", network: .bitcoin), .bitcoinOnchainP2pkh)
    }

    func testPaymentLaunchResultFailureMessageKeys() {
        XCTAssertNil(
            PublicPaykitPaymentLaunchResult.opened(
                paymentRequest: "bitcoin:bcrt1ptest",
                privatePaymentContext: nil
            ).contactPaymentFailureMessageKey
        )
        XCTAssertEqual(PublicPaykitPaymentLaunchResult.noEndpoint.contactPaymentFailureMessageKey, "slashtags__error_pay_empty_msg")
        XCTAssertEqual(PublicPaykitPaymentLaunchResult.notOpened.contactPaymentFailureMessageKey, "slashtags__error_pay_not_opened_msg")
        XCTAssertEqual(
            PublicPaykitPaymentLaunchResult.waitingForUpdatedPaymentList.contactPaymentFailureMessageKey,
            "slashtags__error_pay_empty_msg"
        )
    }

    func testPayableEndpointsFiltersInvalidDecodedEndpoints() async {
        let payable = await PublicPaykitService.payableEndpoints(from: [
            endpoint(.bitcoinLightningBolt11, value: "not-a-bolt11"),
            endpoint(.bitcoinOnchainP2tr, value: "not-an-address"),
        ])

        XCTAssertTrue(payable.isEmpty)
    }

    func testBuildAvailabilityMarksPublicCleanupPendingForPublishedPublicState() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(true, forKey: "hasConfirmedPublicPaykitEndpoints")

            PaykitFeatureFlags.enforceBuildAvailability(defaults: defaults, isUIEnabled: false)

            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
            XCTAssertFalse(defaults.bool(forKey: "hasConfirmedPublicPaykitEndpoints"))
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
        }
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

    private func clearPaykitDefaults() {
        UserDefaults.standard.removeObject(forKey: PaykitFeatureFlags.uiEnabledKey)
        UserDefaults.standard.removeObject(forKey: PublicPaykitService.publishingEnabledKey)
        UserDefaults.standard.removeObject(forKey: PublicPaykitService.cleanupPendingKey)
        UserDefaults.standard.removeObject(forKey: "hasConfirmedPublicPaykitEndpoints")
        UserDefaults.standard.removeObject(forKey: "publicPaykitBolt11")
        UserDefaults.standard.removeObject(forKey: "publicPaykitBolt11PaymentHash")
        UserDefaults.standard.removeObject(forKey: "publicPaykitBolt11ExpiresAt")
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "PublicPaykitServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
