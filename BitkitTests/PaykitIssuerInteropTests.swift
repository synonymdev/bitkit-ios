@testable import Bitkit
import Foundation
import LDKNode
import Paykit
import XCTest

final class PaykitIssuerInteropTests: XCTestCase {
    func testRequestFixturesMatchIssuerContract() throws {
        let fixtures = try loadFixtures()
        XCTAssertEqual(fixtures.schemaVersion, 1)

        for fixture in fixtures.requestFixtures {
            let record = try paymentRequestRecord(
                asset: fixture.asset,
                endpointIdentifiers: fixture.acceptedPaymentEndpointIdentifiers
            )
            let request = PaykitPaymentRequest(record: record, now: Date(), network: fixture.network.ldkNetwork)

            XCTAssertEqual(request != nil, fixture.accepted, fixture.name)
            XCTAssertEqual(request?.acceptedPaymentEndpointIdentifiers ?? [], fixture.expectedIdentifiers, fixture.name)
        }
    }

    func testEndpointFixturesMatchIssuerContract() throws {
        let fixtures = try loadFixtures()

        for fixture in fixtures.endpointFixtures {
            let endpoint = PublicPaykitService.parseEndpoint(methodId: fixture.identifier, endpointData: fixture.payload)

            XCTAssertEqual(endpoint != nil, fixture.accepted, fixture.name)
            XCTAssertEqual(endpoint?.value, fixture.expectedValue, fixture.name)
            XCTAssertEqual(endpoint?.min, fixture.expectedMin, fixture.name)
            XCTAssertEqual(endpoint?.max, fixture.expectedMax, fixture.name)
        }
    }

    func testRequestFixturesCoverEveryNetworkAndChainIndependentLightningIdentifiers() throws {
        let acceptedFixtures = try loadFixtures().requestFixtures.filter(\.accepted)

        for network in FixtureNetwork.allCases {
            XCTAssertTrue(
                acceptedFixtures.contains {
                    $0.network == network && $0.expectedIdentifiers == ["btc-lightning-bolt11"]
                },
                "Missing Bolt11 fixture for \(network.rawValue)"
            )
            XCTAssertTrue(
                acceptedFixtures.contains {
                    $0.network == network && $0.expectedIdentifiers == ["btc-lightning-lnurl"]
                },
                "Missing LNURL fixture for \(network.rawValue)"
            )
            XCTAssertTrue(
                acceptedFixtures.contains {
                    $0.network == network && $0.expectedIdentifiers == ["btc-\(network.rawValue)-p2wpkh"]
                },
                "Missing on-chain fixture for \(network.rawValue)"
            )
        }
    }

    private func loadFixtures() throws -> IssuerInteropFixtures {
        let bundle = Bundle(for: Self.self)
        let bundledURL = bundle.url(
            forResource: "paykit-issuer-interoperability",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) ?? bundle.url(forResource: "paykit-issuer-interoperability", withExtension: "json")
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/paykit-issuer-interoperability.json")
        let data = try Data(contentsOf: bundledURL ?? sourceURL)
        return try JSONDecoder().decode(IssuerInteropFixtures.self, from: data)
    }

    private func paymentRequestRecord(asset: String, endpointIdentifiers: [String]) throws -> PaymentRequestRecord {
        try PaymentRequestRecord(
            counterparty: "pubkyissuerfixture",
            counterpartyReceiverPath: PaykitReceiverPath.server,
            paymentRequestId: "71300000-0000-4000-8000-000000000001",
            localRole: .payer,
            state: .proposed,
            proposalStreamItemId: 1,
            proposalOutboundMessageId: nil,
            proposalOutboundStatus: nil,
            proposalEventId: "71300000-0000-4000-8000-000000000002",
            terms: PaymentRequestTerms(
                amount: PaymentRequestAmount(value: "0.001", asset: asset),
                paymentReference: PaymentReference(text: "marketplace-order-713"),
                proposalExpiresAt: nil,
                recurrence: nil,
                acceptedPaymentEndpointIdentifiers: endpointIdentifiers,
                metadata: PrivateJsonObject(text: #"{"order":"713"}"#)
            ),
            acceptedEventId: nil,
            acceptedOutboundStatus: nil,
            rejectedEventId: nil,
            rejectedOutboundStatus: nil,
            canceledEventId: nil,
            canceledOutboundStatus: nil,
            paymentProofs: [],
            lastStreamItemId: 1,
            lastOutboundMessageId: nil,
            lastOutboundStatus: nil,
            lastEventAt: "2026-09-02T12:00:00Z",
            invalidReason: nil
        )
    }
}

private struct IssuerInteropFixtures: Decodable {
    let schemaVersion: Int
    let requestFixtures: [RequestFixture]
    let endpointFixtures: [EndpointFixture]
}

private struct RequestFixture: Decodable {
    let name: String
    let network: FixtureNetwork
    let asset: String
    let acceptedPaymentEndpointIdentifiers: [String]
    let accepted: Bool
    let expectedIdentifiers: [String]
}

private struct EndpointFixture: Decodable {
    let name: String
    let identifier: String
    let payload: String
    let accepted: Bool
    let expectedValue: String?
    let expectedMin: String?
    let expectedMax: String?
}

private enum FixtureNetwork: String, CaseIterable, Decodable {
    case bitcoin
    case testnet
    case signet
    case regtest

    var ldkNetwork: LDKNode.Network {
        switch self {
        case .bitcoin: .bitcoin
        case .testnet: .testnet
        case .signet: .signet
        case .regtest: .regtest
        }
    }
}
