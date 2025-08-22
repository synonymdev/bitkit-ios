import SwiftUI

struct LoadingView: View {
    @State private var outerRotation: Double = 0
    @State private var innerRotation: Double = 0
    @State private var imageRotation: Double = 0

    var body: some View {
        ZStack(alignment: .center) {
            // Outer ellipse
            Image("ellipse-outer-purple")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 311, height: 311)
                .rotationEffect(.degrees(outerRotation))

            // Inner ellipse
            Image("ellipse-inner-purple")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 207, height: 207)
                .rotationEffect(.degrees(innerRotation))

            // Image
            Image("coin-stack-4")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 330, height: 330)
                .rotationEffect(.degrees(imageRotation))
        }
        .frame(width: 320, height: 320)
        .clipped()
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                outerRotation = -180
            }

            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                innerRotation = 180
            }

            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                imageRotation = 20
            }
        }
    }
}

struct SendQuickpay: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @Binding var navigationPath: [SendRoute]

    var body: some View {
        VStack {
            SheetHeader(title: t("wallet__send_quickpay__nav_title"))

            if let invoice = app.scannedLightningInvoice {
                MoneyStack(sats: Int(invoice.amountSatoshis), showSymbol: true)
            }

            Spacer()

            LoadingView()

            Spacer()

            DisplayText(t("wallet__send_quickpay__title"), accentColor: .purpleAccent)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .sheetBackground()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            Task {
                try await performPayment()
            }
        }
    }

    private func performPayment() async throws {
        var bolt11Invoice: String?

        // Handle LNURL Pay
        if let lnurlPayData = app.lnurlPayData {
            let amount = lnurlPayData.minSendable

            // Set the amount for the success screen
            wallet.sendAmountSats = amount

            bolt11Invoice = try await LnurlHelper.fetchLnurlInvoice(
                callbackUrl: lnurlPayData.callback,
                amount: amount
            )
        } else if let scannedInvoice = app.scannedLightningInvoice {
            wallet.sendAmountSats = scannedInvoice.amountSatoshis
            bolt11Invoice = scannedInvoice.bolt11
        }

        guard let bolt11 = bolt11Invoice else {
            throw NSError(
                domain: "Payment", code: -1, userInfo: [NSLocalizedDescriptionKey: "No Lightning invoice found"]
            )
        }

        do {
            let paymentHash = try await wallet.send(bolt11: bolt11, sats: wallet.sendAmountSats)
            Logger.info("Quickpay payment successful: \(paymentHash)")
            navigationPath.append(.success(paymentHash))
        } catch {
            Logger.error("Quickpay payment failed: \(error)")

            // TODO: remove toast and use failure screen instead
            app.toast(error)

            // TODO: this is a hack to make sure the navigation binding is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                navigationPath.append(.failure)
            }
        }
    }
}
