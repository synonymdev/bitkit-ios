import Foundation
import Paykit

enum PaykitSubscriptionProposal {
    // Paykit's proposal wire format is carried in a pubky-noise message capped at 1,000 UTF-8 bytes.
    static let maximumMessageBytes = 1000
    static let reservedIconURI = "pubky://" + String(repeating: "x", count: 122)

    static func validate(_ terms: Paykit.PaymentRequestTerms) throws {
        guard try encodedSize(terms) <= maximumMessageBytes else {
            throw PaykitPaymentRequestError.subscriptionTooLong
        }
    }

    static func encodedSize(_ terms: Paykit.PaymentRequestTerms) throws -> Int {
        guard let recurrence = terms.recurrence else {
            throw PaykitPaymentRequestError.requestUnavailable
        }
        let metadata = try JSONSerialization.jsonObject(with: Data(terms.metadata.exportText().utf8))
        let uuid = "00000000-0000-0000-0000-000000000000"
        let wire: [String: Any] = [
            "version": 1,
            "kind": "paykit.payment_request",
            "event_id": uuid,
            "payment_request_id": uuid,
            "request": [
                "amount": ["value": terms.amount.value, "asset": terms.amount.asset],
                "payment_reference": terms.paymentReference.exportText(),
                "proposal_expires_at": terms.proposalExpiresAt as Any? ?? NSNull(),
                "recurrence": [
                    "every": recurrence.every,
                    "unit": recurrence.unit,
                    "starts_at": recurrence.startsAt,
                    "anchor": recurrence.anchor,
                    "ends_at": recurrence.endsAt as Any? ?? NSNull(),
                ],
                "accepted_payment_endpoint_identifiers": terms.acceptedPaymentEndpointIdentifiers,
                "metadata": metadata,
            ],
        ]
        return try JSONSerialization.data(withJSONObject: wire, options: [.withoutEscapingSlashes]).count
    }
}
