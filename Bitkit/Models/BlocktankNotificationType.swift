import Foundation

enum BlocktankNotificationType: String {
    case incomingHtlc
    case mutualClose
    case orderPaymentConfirmed
    case cjitPaymentArrived
    case wakeToTimeout

    var feature: String {
        return "blocktank.\(rawValue)"
    }
}
