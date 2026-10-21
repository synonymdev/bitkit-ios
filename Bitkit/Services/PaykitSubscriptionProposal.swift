import Foundation
import Paykit

enum PaykitSubscriptionProposal {
    static let reservedIconURI = "pubky://" + String(repeating: "x", count: 122)

    static func validate(_ terms: Paykit.PaymentRequestTerms) throws {
        guard try encodedSize(terms) <= PaykitSdkService.maximumMessageBytes else {
            throw PaykitPaymentRequestError.subscriptionTooLong
        }
    }

    static func encodedSize(_ terms: Paykit.PaymentRequestTerms) throws -> Int {
        guard let recurrence = terms.recurrence, terms.paymentEndpoints == nil else {
            throw PaykitPaymentRequestError.requestUnavailable
        }
        let metadata = try JSONSerialization.jsonObject(with: Data(terms.metadata.exportText().utf8))
        let uuid = "00000000-0000-0000-0000-000000000000"
        var request: [String: Any] = [
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
            "required_app_id": terms.requiredAppId as Any? ?? NSNull(),
            "metadata": metadata,
        ]
        if let conversion = terms.conversion {
            switch conversion {
            case let .fixed(rates): request["conversion"] = ["type": "fixed", "rates": rates.map { ["asset": $0.asset, "value": $0.value] }]
            case .perPeriod: request["conversion"] = ["type": "per_period"]
            }
        }
        if let deadline = terms.paymentDeadline {
            switch deadline {
            case let .at(timestamp): request["payment_deadline"] = ["type": "at", "timestamp": timestamp]
            case let .periodStart(seconds): request["payment_deadline"] = ["type": "period_start", "seconds": seconds]
            }
        }
        let wire: [String: Any] = ["version": 1, "kind": "paykit.payment_request", "app_id": "bitkit",
                                   "event_id": uuid, "payment_request_id": uuid, "request": request]
        return try JSONSerialization.data(withJSONObject: wire, options: [.withoutEscapingSlashes]).count
    }
}
