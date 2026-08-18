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
        currency: CurrencyViewModel,
        spendStore: QuickPaySpendStore = .shared
    ) -> Bool {
        guard settings.enableQuickpay else {
            return false
        }

        guard let amountSats = QuickPayLimits.paymentAmountSats(app: app), amountSats > 0 else {
            return false
        }

        return isWithinThreshold(amountSats: amountSats, settings: settings, currency: currency)
            && isWithinDailyCap(amountSats: amountSats, settings: settings, currency: currency, spendStore: spendStore)
    }

    private static func isWithinThreshold(
        amountSats: UInt64,
        settings: SettingsViewModel,
        currency: CurrencyViewModel
    ) -> Bool {
        let quickpayAmountSats = currency.convert(fiatAmount: settings.quickpayAmount, from: QuickPayLimits.usdCurrencyCode) ?? 0
        return quickpayAmountSats > 0 && amountSats <= quickpayAmountSats
    }

    private static func isWithinDailyCap(
        amountSats: UInt64,
        settings: SettingsViewModel,
        currency: CurrencyViewModel,
        spendStore: QuickPaySpendStore
    ) -> Bool {
        let multiplier = QuickPayLimits.sanitizedMultiplier(settings.quickpayDailyLimitMultiplier)
        guard let dailyCapUsd = QuickPayLimits.dailyCapUsd(
            thresholdUsd: settings.quickpayAmount,
            multiplier: multiplier,
            currency: currency
        ), let amountUsd = QuickPayLimits.usdValue(sats: amountSats, currency: currency) else {
            return false
        }

        let dayKey = QuickPaySpendStore.dayKey()
        let spentUsdToday = spendStore.spentUsd(forDayKey: dayKey)
        if spentUsdToday + amountUsd <= dailyCapUsd {
            return true
        }

        Logger.info(
            "Skipping QuickPay: daily spend '\(spentUsdToday)' + '\(amountUsd)' exceeds cap '\(dailyCapUsd)'"
        )
        return false
    }

    /// Centralized method to open the appropriate sheet based on the current state
    static func openPaymentSheet(
        app: AppViewModel,
        currency: CurrencyViewModel,
        settings: SettingsViewModel,
        sheetViewModel: SheetViewModel,
        spendStore: QuickPaySpendStore = .shared
    ) {
        // Handle LNURL withdraw
        if let lnurlWithdrawData = app.lnurlWithdrawData {
            Logger.info("LNURL withdraw data: \(lnurlWithdrawData)")
            if lnurlWithdrawData.isFixedAmount {
                sheetViewModel.showSheet(.lnurlWithdraw, data: LnurlWithdrawConfig(view: .confirm))
            } else {
                sheetViewModel.showSheet(.lnurlWithdraw, data: LnurlWithdrawConfig(view: .amount))
            }
            return
        }

        let shouldUseQuickpay = shouldUseQuickpay(app: app, settings: settings, currency: currency, spendStore: spendStore)

        // Handle Lightning address / LNURL pay
        if let lnurlPayData = app.lnurlPayData {
            if shouldUseQuickpay {
                sheetViewModel.showSheet(.send, data: SendConfig(view: .quickpay))
            } else if lnurlPayData.isFixedAmount {
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
        settings: SettingsViewModel,
        spendStore: QuickPaySpendStore = .shared
    ) -> SendRoute? {
        if let lnurlWithdrawData = app.lnurlWithdrawData {
            if lnurlWithdrawData.isFixedAmount {
                return .lnurlWithdrawConfirm
            } else {
                return .lnurlWithdrawAmount
            }
        }

        let shouldUseQuickpay = shouldUseQuickpay(app: app, settings: settings, currency: currency, spendStore: spendStore)

        // Handle Lightning address / LNURL pay
        if let lnurlPayData = app.lnurlPayData {
            if shouldUseQuickpay {
                return .quickpay
            } else if lnurlPayData.isFixedAmount {
                return .lnurlPayConfirm
            } else {
                return .lnurlPayAmount
            }
        }

        // Handle lightning invoice
        if let invoice = app.scannedLightningInvoice {
            let amount = invoice.amountSatoshis

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
        if let _ = app.scannedOnchainInvoice {
            return .amount
        }

        // No valid invoice data
        return nil
    }

    static func contactPaymentRoute(
        app: AppViewModel,
        currency: CurrencyViewModel,
        settings: SettingsViewModel,
        spendStore: QuickPaySpendStore = .shared
    ) -> SendRoute? {
        guard let route = appropriateSendRoute(app: app, currency: currency, settings: settings, spendStore: spendStore) else {
            return nil
        }

        switch route {
        case .quickpay:
            if let lnurlPayData = app.lnurlPayData {
                return lnurlPayData.isFixedAmount ? .lnurlPayConfirm : .lnurlPayAmount
            }

            if let invoice = app.scannedLightningInvoice {
                return invoice.amountSatoshis == 0 ? .amount : .confirm
            }

            if app.scannedOnchainInvoice != nil {
                return .amount
            }

            return route
        case .confirm:
            if let invoice = app.scannedLightningInvoice {
                return invoice.amountSatoshis == 0 ? .amount : .confirm
            }
            return route
        default:
            return route
        }
    }
}
