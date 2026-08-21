import SwiftUI

struct SendQuickpay: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var currency: CurrencyViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @Binding var navigationPath: [SendRoute]
    let routingCacheResetAttempted: Bool
    var replaceQuickPay: (SendRoute) -> Void
    @State private var didStartPayment = false

    var body: some View {
        VStack {
            SheetHeader(title: t("wallet__send_quickpay__nav_title"))

            if let lnurlPayData = app.lnurlPayData {
                MoneyStack(sats: Int(lnurlPayData.minSendableSat), showSymbol: true)
            } else if let invoice = app.scannedLightningInvoice {
                MoneyStack(sats: Int(invoice.amountSatoshis), showSymbol: true)
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
            guard !didStartPayment else { return }
            didStartPayment = true
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
                )
            )
        }
        .onDisappear {
            QuickPayPaymentCoordinator.shared.detach()
        }
    }
}
