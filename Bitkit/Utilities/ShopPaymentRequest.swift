import BitkitCore
import Foundation

enum ScanHandlingScope {
    case unrestricted
    case paymentRequests
}

enum ShopPaymentRequest {
    static func isSupported(_ data: BitkitCore.Scanner) -> Bool {
        switch data {
        case .onChain, .lightning, .lnurlPay:
            return true
        default:
            return false
        }
    }
}

enum ShopPaymentRequestError: LocalizedError {
    case unsupportedRequest

    var errorDescription: String? {
        t("other__scan__error__generic")
    }
}
