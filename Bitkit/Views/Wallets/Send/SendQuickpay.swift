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

    @Binding var navigationPath: [SendView]

    var body: some View {
        VStack {
            SheetHeader(title: localizedString("wallet__send_quickpay__nav_title"))

            if let invoice = app.scannedLightningInvoice {
                MoneyStack(sats: Int(invoice.amountSatoshis))
            }

            Spacer()

            LoadingView()

            Spacer()

            DisplayText(localizedString("wallet__send_quickpay__title"), accentColor: .purpleAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .onAppear {
            Task {
                try await performPayment()
            }
        }
    }

    private func performPayment() async throws {
        do {
            if let bolt11 = app.scannedLightningBolt11Invoice {
                // A LN payment can throw an error right away, be successful right away, or take a while to complete/fail because it's retrying different paths.
                // So we need to handle all these cases here.
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    Task {
                        do {
                            let paymentHash = try await wallet.send(
                                bolt11: bolt11,
                                sats: app.sendAmountSats,
                                onSuccess: {
                                    Logger.info("Lightning payment successful")
                                    // app.resetSendState()
                                    continuation.resume()
                                    navigationPath.append(.success)
                                },
                                onFail: { reason in
                                    Logger.error("Lightning payment failed: \(reason)")
                                    app.toast(type: .error, title: "Payment failed", description: reason)
                                    continuation.resume(
                                        throwing: NSError(domain: "Lightning", code: -1, userInfo: [NSLocalizedDescriptionKey: reason]))
                                }
                            )
                            Logger.info("Lightning send initiated with payment hash: \(paymentHash)")
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } else {
                throw NSError(
                    domain: "Payment", code: -1, userInfo: [NSLocalizedDescriptionKey: "No Lightning invoice found"])
            }
        } catch {
            app.toast(error)
            Logger.error("Error sending: \(error)")
            throw error // Passing error up to SwipeButton so it knows to reset state
        }
    }
}
