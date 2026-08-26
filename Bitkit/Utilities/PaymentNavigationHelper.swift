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
        spendStore: QuickPaySpendStore = .shared,
        coordinator: QuickPayPaymentCoordinator? = nil
    ) -> Bool {
        guard let amountSats = QuickPayLimits.paymentAmountSats(app: app), amountSats > 0 else {
            return false
        }

        let coordinator = coordinator ?? .shared
        if let hash = app.scannedLightningInvoice?.paymentHash.hex, coordinator.hasOpen(hash) {
            return true
        }

        return spendStore.canApply(
            amountSats: amountSats,
            enabled: settings.enableQuickpay,
            thresholdUsd: settings.quickpayAmount,
            multiplier: settings.quickpayDailyLimitMultiplier,
            rates: .live(currency)
        )
    }

    /// Centralized method to open the appropriate sheet based on the current state
    static func openPaymentSheet(
        app: AppViewModel,
        currency: CurrencyViewModel,
        settings: SettingsViewModel,
        sheetViewModel: SheetViewModel,
        spendStore: QuickPaySpendStore = .shared,
        coordinator: QuickPayPaymentCoordinator? = nil
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

        let shouldUseQuickpay = shouldUseQuickpay(
            app: app,
            settings: settings,
            currency: currency,
            spendStore: spendStore,
            coordinator: coordinator
        )

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
        spendStore: QuickPaySpendStore = .shared,
        coordinator: QuickPayPaymentCoordinator? = nil
    ) -> SendRoute? {
        if let lnurlWithdrawData = app.lnurlWithdrawData {
            if lnurlWithdrawData.isFixedAmount {
                return .lnurlWithdrawConfirm
            } else {
                return .lnurlWithdrawAmount
            }
        }

        let shouldUseQuickpay = shouldUseQuickpay(
            app: app,
            settings: settings,
            currency: currency,
            spendStore: spendStore,
            coordinator: coordinator
        )

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

    static func confirmRouteAfterQuickPayCap(app: AppViewModel) -> SendRoute {
        if let lnurlPayData = app.lnurlPayData {
            return lnurlPayData.isFixedAmount ? .lnurlPayConfirm : .lnurlPayAmount
        }

        if let invoice = app.scannedLightningInvoice, invoice.amountSatoshis == 0 {
            return .amount
        }

        return .confirm
    }

    static func replacingQuickPay(
        in path: [SendRoute],
        root: SendRoute,
        with route: SendRoute
    ) -> (root: SendRoute, path: [SendRoute]) {
        if root == .quickpay {
            return (route, [])
        }

        if let index = path.lastIndex(of: .quickpay) {
            var nextPath = Array(path.prefix(index))
            nextPath.append(route)
            return (root, nextPath)
        }

        return (root, path + [route])
    }

    static func contactPaymentRoute(
        app: AppViewModel,
        currency: CurrencyViewModel,
        settings: SettingsViewModel,
        spendStore: QuickPaySpendStore = .shared,
        coordinator: QuickPayPaymentCoordinator? = nil
    ) -> SendRoute? {
        guard let route = appropriateSendRoute(
            app: app,
            currency: currency,
            settings: settings,
            spendStore: spendStore,
            coordinator: coordinator
        ) else {
            return nil
        }

        if app.contactPaymentContext?.incomingPaymentRequest != nil {
            switch route {
            case .quickpay, .amount:
                return app.lnurlPayData == nil ? .confirm : .lnurlPayConfirm
            case .lnurlPayAmount:
                return .lnurlPayConfirm
            default:
                return route
            }
        }

        switch route {
        case .quickpay:
            return confirmRouteAfterQuickPayCap(app: app)
        default:
            return route
        }
    }

    static func openPrivateContactPayment(
        publicKey: String,
        app: AppViewModel,
        currency: CurrencyViewModel,
        settings: SettingsViewModel,
        wallet: WalletViewModel,
        alternativeOnchainBalanceSats: UInt64 = 0,
        present: (SendRoute) -> Void
    ) async {
        do {
            let result = try await PrivatePaykitService.shared.beginSavedContactPayment(to: publicKey, wallet: wallet)
            switch result {
            case let .opened(paymentRequest, privatePaymentContext):
                let context = ContactPaymentContext(publicKey: publicKey, privatePaymentContext: privatePaymentContext)
                guard app.claimContactPaymentContext(context) else { return }

                do {
                    try await app.handleScannedData(
                        paymentRequest,
                        claimedContactPaymentContext: context,
                        alternativeOnchainBalanceSats: alternativeOnchainBalanceSats
                    )
                } catch is CancellationError {
                    if app.ownsContactPaymentContext(context) {
                        app.resetSendState()
                    }
                    return
                } catch {
                    guard app.ownsContactPaymentContext(context) else { return }
                    app.resetSendState()
                    Logger.warn("Failed to decode private contact payment request", context: "PaymentNavigationHelper")
                    app.toast(
                        type: .warning,
                        title: t("slashtags__error_pay_title"),
                        description: t("slashtags__error_pay_not_opened_msg")
                    )
                    return
                }

                guard app.ownsContactPaymentContext(context),
                      let route = contactPaymentRoute(app: app, currency: currency, settings: settings)
                else {
                    app.resetSendState()
                    return
                }
                present(route)

            case .noEndpoint, .notOpened, .waitingForUpdatedPaymentList:
                if let messageKey = result.contactPaymentFailureMessageKey {
                    app.toast(type: .warning, title: t("slashtags__error_pay_title"), description: t(messageKey))
                }
            }
        } catch {
            Logger.error(
                "Failed to pay contact \(PubkyPublicKeyFormat.redacted(publicKey)): \(error)",
                context: "PaymentNavigationHelper"
            )
            app.toast(type: .error, title: t("slashtags__error_pay_title"), description: error.localizedDescription)
        }
    }
}
