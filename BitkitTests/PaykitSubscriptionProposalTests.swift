@testable import Bitkit
import Paykit
import UIKit
import XCTest

final class PaykitSubscriptionProposalTests: XCTestCase {
    func testTransportLimitIncludesEnvelopeEndpointsAndPublicIcon() throws {
        let empty = try terms(description: "", iconURI: PaykitSubscriptionProposal.reservedIconURI)
        let available = try PaykitSubscriptionProposal.maximumMessageBytes - (PaykitSubscriptionProposal.encodedSize(empty))
        XCTAssertGreaterThan(available, 0)
        let full = try terms(description: String(repeating: "a", count: available), iconURI: PaykitSubscriptionProposal.reservedIconURI)
        XCTAssertEqual(try PaykitSubscriptionProposal.encodedSize(full), 1000)
        XCTAssertNoThrow(try PaykitSubscriptionProposal.validate(full))
        XCTAssertThrowsError(try PaykitSubscriptionProposal.validate(terms(
            description: String(repeating: "a", count: available + 1),
            iconURI: PaykitSubscriptionProposal.reservedIconURI
        ))) { error in
            XCTAssertEqual(error as? PaykitPaymentRequestError, .subscriptionTooLong)
        }
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
            acceptedPaymentEndpointIdentifiers: ["bitcoin:regtest", "lightning:bolt11", "lightning:lnurl"],
            metadata: PrivateJsonObject(text: String(decoding: data, as: UTF8.self))
        )
    }
}
