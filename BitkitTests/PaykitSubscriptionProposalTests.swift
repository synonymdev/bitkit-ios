@testable import Bitkit
import Paykit
import UIKit
import XCTest

final class PaykitSubscriptionProposalTests: XCTestCase {
    func testTransportLimitIncludesAppIdsEndpointsAndPublicIcon() throws {
        // Paykit's payment-request wire format, without optional request fields.
        let emptyWire = #"""
        {"version":1,"kind":"paykit.payment_request","app_id":"bitkit",
        "event_id":"00000000-0000-0000-0000-000000000000","payment_request_id":"00000000-0000-0000-0000-000000000000",
        "request":{"amount":{"value":"0.001","asset":"btc"},"payment_reference":"bitkit-00000000-0000-0000-0000-000000000000",
        "proposal_expires_at":"2027-01-22T08:00:00.000Z",
        "recurrence":{"every":1,"unit":"month","starts_at":"2027-01-15T08:00:00.000Z","anchor":"2027-01-15T08:00:00.000Z","ends_at":null},
        "accepted_payment_endpoint_identifiers":["btc-regtest-p2wpkh","btc-lightning-bolt11","btc-lightning-lnurl"],"required_app_id":"bitkit",
        "metadata":{"note":"Support","subscription":{"benefits":[],"description":"",
        "icon_uri":"pubky://\#(String(repeating: "x", count: 122))","version":1}}}}
        """#.split(separator: "\n").joined()
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(emptyWire.utf8)))
        XCTAssertEqual(emptyWire.utf8.count, 840)
        let empty = try terms(description: "", iconURI: PaykitSubscriptionProposal.reservedIconURI)
        XCTAssertEqual(try PaykitSubscriptionProposal.encodedSize(empty), emptyWire.utf8.count)
        let full = try terms(description: String(repeating: "a", count: 160), iconURI: PaykitSubscriptionProposal.reservedIconURI)
        XCTAssertEqual(try PaykitSubscriptionProposal.encodedSize(full), 1000)
        XCTAssertNoThrow(try PaykitSubscriptionProposal.validate(full))
        let oversized = try terms(
            description: String(repeating: "a", count: 161),
            iconURI: PaykitSubscriptionProposal.reservedIconURI
        )
        XCTAssertEqual(try PaykitSubscriptionProposal.encodedSize(oversized), 1001)
        XCTAssertThrowsError(try PaykitSubscriptionProposal.validate(oversized)) { error in
            XCTAssertEqual(error as? PaykitPaymentRequestError, .subscriptionTooLong)
        }
    }

    func testSizeIncludesNullableFieldsAndRecurrenceEnd() throws {
        var request = try terms(description: "")
        let base = try PaykitSubscriptionProposal.encodedSize(request)
        request.requiredAppId = nil
        XCTAssertEqual(try PaykitSubscriptionProposal.encodedSize(request), base - 4)
        request.proposalExpiresAt = nil
        XCTAssertEqual(try PaykitSubscriptionProposal.encodedSize(request), base - 26)
        request.recurrence?.endsAt = "2028-01-15T08:00:00.000Z"
        XCTAssertEqual(try PaykitSubscriptionProposal.encodedSize(request), base - 4)
        request.requiredAppId = "checkout"
        XCTAssertEqual(try PaykitSubscriptionProposal.encodedSize(request), base + 2)
    }

    func testSubscriptionSizeIncludesConversionAndDeadlineAndRejectsUnmodeledEndpoints() throws {
        var boundEndpoints = try terms(description: "")
        boundEndpoints.paymentEndpoints = ["btc-regtest-p2wpkh": #"{"address":"bcrt1qexample"}"#]
        XCTAssertThrowsError(try PaykitSubscriptionProposal.validate(boundEndpoints)) { error in
            XCTAssertEqual(error as? PaykitPaymentRequestError, .requestUnavailable)
        }
        var conversion = try terms(description: "")
        conversion.conversion = .perPeriod
        var deadline = try terms(description: "")
        deadline.paymentDeadline = .periodStart(seconds: 3600)
        let base = try PaykitSubscriptionProposal.encodedSize(terms(description: ""))
        XCTAssertEqual(try PaykitSubscriptionProposal.encodedSize(conversion), base + #","conversion":{"type":"per_period"}"#.utf8.count)
        XCTAssertEqual(
            try PaykitSubscriptionProposal.encodedSize(deadline),
            base + #","payment_deadline":{"type":"period_start","seconds":3600}"#.utf8.count
        )
    }

    func testSizeCountsUTF8AndJSONEscapingRatherThanCharacters() throws {
        let base = try PaykitSubscriptionProposal.encodedSize(terms(description: ""))
        XCTAssertEqual(try PaykitSubscriptionProposal.encodedSize(terms(description: "💜")), base + 4)
        XCTAssertEqual(try PaykitSubscriptionProposal.encodedSize(terms(description: "\"\n\\")), base + 6)
        XCTAssertEqual(try PaykitSubscriptionProposal.encodedSize(terms(description: "https://example.com")), base + 19)
    }

    @MainActor
    func testSubscriptionIconIsDownsampledAndInvalidDataIsRejected() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1200), format: format).image { context in
            UIColor.purple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1200))
        }
        let input = try XCTUnwrap(image.pngData())
        let compressed = try PaykitPaymentRequestService.compressedSubscriptionIcon(input)
        let output = try XCTUnwrap(UIImage(data: compressed)?.cgImage)
        XCTAssertEqual(output.width, 400)
        XCTAssertEqual(output.height, 200)
        XCTAssertThrowsError(try PaykitPaymentRequestService.compressedSubscriptionIcon(Data([0, 1, 2])))
    }

    private func terms(description: String, iconURI: String? = nil) throws -> PaymentRequestTerms {
        var subscription: [String: Any] = ["version": 1, "description": description, "benefits": []]
        subscription["icon_uri"] = iconURI
        let data = try JSONSerialization.data(withJSONObject: ["note": "Support", "subscription": subscription])
        return try PaymentRequestTerms(
            amount: PaymentRequestAmount(value: "0.001", asset: "btc"),
            paymentReference: PaymentReference(text: "bitkit-00000000-0000-0000-0000-000000000000"),
            proposalExpiresAt: "2027-01-22T08:00:00.000Z",
            recurrence: PaymentRequestRecurrence(
                every: 1,
                unit: "month",
                startsAt: "2027-01-15T08:00:00.000Z",
                anchor: "2027-01-15T08:00:00.000Z",
                endsAt: nil
            ),
            acceptedPaymentEndpointIdentifiers: ["btc-regtest-p2wpkh", "btc-lightning-bolt11", "btc-lightning-lnurl"],
            paymentEndpoints: nil,
            requiredAppId: "bitkit",
            conversion: nil,
            paymentDeadline: nil,
            metadata: PrivateJsonObject(text: String(decoding: data, as: UTF8.self))
        )
    }
}
