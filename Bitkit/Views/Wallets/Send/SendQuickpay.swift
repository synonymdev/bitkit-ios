import SwiftUI

struct SendQuickpay: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @Binding var navigationPath: [SendRoute]
    let routingCacheResetAttempted: Bool
    var replaceQuickPay: (SendRoute) -> Void
    let sessionID: QuickPayPaymentCoordinator.SessionID
    let isCurrentPresentation: () -> Bool
    @State private var displayedSats: UInt64?

    private var paymentSats: UInt64? {
        displayedSats ?? app.lnurlPayData?.minSendableSat ?? app.scannedLightningInvoice?.amountSatoshis
    }

    var body: some View {
        VStack {
            SheetHeader(title: t("wallet__send_quickpay__nav_title"))

            if let paymentSats {
                MoneyStack(sats: Int(paymentSats), showSymbol: true)
            }

            Spacer(minLength: 32)

            EllipseLoader(variant: .quickpay)
                .padding(.horizontal, 16)

            Spacer(minLength: 32)

            DisplayText(t("wallet__send_quickpay__title"), accentColor: .purpleAccent)
        }
        .navigationBarHidden(true)
        .allowSwipeBack(false)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard isCurrentPresentation(), !app.isHandlingScannedData else { return }
            guard Self.startsAutomatically(app: app, sessionID: sessionID) else {
                // Chosen before the app locked: the payer reviews it instead.
                replaceQuickPay(PaymentNavigationHelper.confirmRouteAfterQuickPayCap(app: app))
                return
            }
            if displayedSats == nil {
                displayedSats = app.lnurlPayData?.minSendableSat ?? app.scannedLightningInvoice?.amountSatoshis
            }
            let recoveryOnly = Self.isRecoveryOnly(app: app, sessionID: sessionID)
            QuickPayPaymentCoordinator.shared.pay(
                app: app,
                wallet: wallet,
                settings: settings,
                currency: currency,
                presentation: QuickPayPaymentCoordinator.Presentation(
                    appendRoute: { navigationPath.append($0) },
                    replaceQuickPay: replaceQuickPay,
                    addPendingPaymentHash: { app.addPendingPaymentHash($0) },
                    routingCacheResetAttempted: routingCacheResetAttempted
                ),
                sessionID: sessionID,
                recoveryOnly: recoveryOnly
            )
        }
    }

    /// Whether the payment starts as the screen appears. A payment already started reattaches, and an invoice the
    /// coordinator already tracks (a rescan of a payment in progress) replays its status. Only a new submission chosen
    /// before the app locked waits for review.
    @MainActor
    static func startsAutomatically(
        app: AppViewModel,
        sessionID: QuickPayPaymentCoordinator.SessionID,
        coordinator: QuickPayPaymentCoordinator? = nil
    ) -> Bool {
        let coordinator = coordinator ?? .shared
        let paymentHash = app.scannedLightningInvoice?.paymentHash.hex ?? ""
        return coordinator.isAttached(to: sessionID) || coordinator.hasOpen(paymentHash) || !app.didLockSinceQuickPayWasChosen
    }

    /// Whether a start may only replay a tracked payment: after a lock, a new submission needs review, so a payment
    /// that is no longer tracked by the time the coordinator runs falls back to it instead of being sent.
    @MainActor
    static func isRecoveryOnly(
        app: AppViewModel,
        sessionID: QuickPayPaymentCoordinator.SessionID,
        coordinator: QuickPayPaymentCoordinator? = nil
    ) -> Bool {
        let coordinator = coordinator ?? .shared
        return !coordinator.isAttached(to: sessionID) && app.didLockSinceQuickPayWasChosen
    }
}
