import BitkitCore
import Foundation

enum ScanHandlingScope {
    case unrestricted
    case paymentRequests
    case onchainPayments
}

enum ShopPaymentRequest {
    static func decodingErrorToast(for error: Error) -> Toast? {
        guard error is DecodingError else { return nil }
        return Toast(
            type: .error,
            title: t("other__scan_err_decoding"),
            description: t("other__scan__error__generic"),
            accessibilityIdentifier: "InvalidAddressToast"
        )
    }

    static func isSupported(_ data: BitkitCore.Scanner) -> Bool {
        switch data {
        case .onChain, .lightning, .lnurlPay:
            return true
        default:
            return false
        }
    }

    static func isOnchainPayment(_ data: BitkitCore.Scanner) -> Bool {
        if case .onChain = data {
            return true
        }
        return false
    }
}

enum ScanHandlingError: LocalizedError {
    case pubkyAuthRequest
    case unsupportedRequest

    var errorDescription: String? {
        t("other__scan__error__generic")
    }
}
