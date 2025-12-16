import Foundation

enum BlocktankNotificationType: String {
    case incomingHtlc
    case mutualClose
    case orderPaymentConfirmed
    case cjitPaymentArrived
    case wakeToTimeout
    
    // Paykit notification types
    case paykitPaymentRequest
    case paykitSubscriptionDue
    case paykitAutoPayExecuted
    case paykitSubscriptionFailed

    var feature: String {
        if rawValue.hasPrefix("paykit") {
            return "paykit.\(rawValue)"
        }
        return "blocktank.\(rawValue)"
    }
}
