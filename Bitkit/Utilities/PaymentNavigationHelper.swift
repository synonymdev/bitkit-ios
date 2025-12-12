import BitkitCore
import Foundation

@MainActor
struct PaymentNavigationHelper {
    /// Determines if quickpay should be used for the current app state
    /// - Parameters:
    ///   - app: The app view model containing the current invoice state
    ///   - settings: The settings view model
    ///   - currency: The currency view model
    /// - Returns: True if quickpay should be used, false otherwise
    static func shouldUseQuickpay(
        app: AppViewModel,
        settings: SettingsViewModel,
        currency: CurrencyViewModel
    ) -> Bool {
        // Check if quickpay is enabled
        guard settings.enableQuickpay else {
            return false
        }

        // We need a lightning invoice to use quickpay
        guard app.scannedLightningInvoice != nil else {
            return false
        }

        // Convert quickpay amount from USD to sats
        let quickpayAmountSats = currency.convert(fiatAmount: settings.quickpayAmount, from: "USD") ?? 0
        guard quickpayAmountSats > 0 else {
            return false
        }

        // Check LNURL pay
        if let lnurlPayData = app.lnurlPayData {
            // For LNURL pay, check if it's a fixed amount and within quickpay threshold
            return lnurlPayData.minSendable == lnurlPayData.maxSendable && lnurlPayData.minSendable <= quickpayAmountSats
        }

        // Check regular lightning invoice
        return app.scannedLightningInvoice!.amountSatoshis <= quickpayAmountSats
    }

    /// Centralized method to open the appropriate sheet based on the current state
    static func openPaymentSheet(
        app: AppViewModel,
        currency: CurrencyViewModel,
        settings: SettingsViewModel,
        sheetViewModel: SheetViewModel
    ) {
        // Handle LNURL withdraw
        if let lnurlWithdrawData = app.lnurlWithdrawData {
            Logger.info("LNURL withdraw data: \(lnurlWithdrawData)")
            if lnurlWithdrawData.minWithdrawable == lnurlWithdrawData.maxWithdrawable {
                sheetViewModel.showSheet(.lnurlWithdraw, data: LnurlWithdrawConfig(view: .confirm))
            } else {
                sheetViewModel.showSheet(.lnurlWithdraw, data: LnurlWithdrawConfig(view: .amount))
            }
            return
        }

        let shouldUseQuickpay = shouldUseQuickpay(app: app, settings: settings, currency: currency)

        // Handle Lightning address / LNURL pay
        if let lnurlPayData = app.lnurlPayData {
            if shouldUseQuickpay {
                sheetViewModel.showSheet(.send, data: SendConfig(view: .quickpay))
            } else if lnurlPayData.minSendable == lnurlPayData.maxSendable {
                sheetViewModel.showSheet(.send, data: SendConfig(view: .lnurlPayConfirm))
            } else {
                sheetViewModel.showSheet(.send, data: SendConfig(view: .lnurlPayAmount))
            }
            return
        }

        // Handle lightning invoice
        if app.scannedLightningInvoice != nil {
            let amount = app.scannedLightningInvoice!.amountSatoshis

            if amount > 0 && shouldUseQuickpay {
                sheetViewModel.showSheet(.send, data: SendConfig(view: .quickpay))
            } else {
                if amount == 0 {
                    sheetViewModel.showSheet(.send, data: SendConfig(view: .amount))
                } else {
                    sheetViewModel.showSheet(.send, data: SendConfig(view: .confirm))
                }
            }
            return
        }

        // Handle onchain invoice
        if app.scannedOnchainInvoice != nil {
            sheetViewModel.showSheet(.send, data: SendConfig(view: .amount))
            return
        }
    }

    /// Returns the appropriate send route for navigation-based views
    /// This allows views using NavigationStack to get the correct route
    /// - Returns: The appropriate send route, or nil if no route should be shown
    static func appropriateSendRoute(
        app: AppViewModel,
        currency: CurrencyViewModel,
        settings: SettingsViewModel
    ) -> SendRoute {
        if let lnurlWithdrawData = app.lnurlWithdrawData {
            if lnurlWithdrawData.minWithdrawable == lnurlWithdrawData.maxWithdrawable {
                return .lnurlWithdrawConfirm
            } else {
                return .lnurlWithdrawAmount
            }
        }

        let shouldUseQuickpay = shouldUseQuickpay(app: app, settings: settings, currency: currency)

        // Handle Lightning address / LNURL pay
        if let lnurlPayData = app.lnurlPayData {
            if shouldUseQuickpay {
                return .quickpay
            } else if lnurlPayData.minSendable == lnurlPayData.maxSendable {
                return .lnurlPayConfirm
            } else {
                return .lnurlPayAmount
            }
        }

        // Handle lightning invoice
        if app.scannedLightningInvoice != nil {
            let amount = app.scannedLightningInvoice!.amountSatoshis

            if amount > 0 && shouldUseQuickpay {
                return .quickpay
            } else {
                if amount == 0 {
                    return .amount
                } else {
                    return .confirm
                }
            }
        }

        // Handle onchain invoice
        return .amount
    }
}
