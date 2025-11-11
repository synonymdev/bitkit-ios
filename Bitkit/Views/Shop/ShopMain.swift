import SwiftUI
import WebKit

struct ShopMain: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var settings: SettingsViewModel

    let page: String

    private var uri: String {
        let baseUrl = "https://embed.bitrefill.com"
        let paymentMethod = "bitcoin" // Payment method "bitcoin" gives a unified invoice
        let params = "?ref=\(Env.bitrefillRef)&paymentMethod=\(paymentMethod)&theme=dark&utm_source=\(Env.appName)"
        return "\(baseUrl)/\(page)/\(params)"
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(
                title: t("other__shop__main__nav_title"),
                showMenuButton: false
            )

            ShopWebView(
                url: uri,
                onMessage: handleMessage
            )
            .padding(.top, 16)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
    }

    private func handleMessage(_ message: String) {
        // Parse the message as a JSON-encoded string
        guard let messageData = message.data(using: .utf8),
              let jsonString = try? JSONSerialization.jsonObject(with: messageData, options: .allowFragments) as? String,
              let innerData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any],
              let event = json["event"] as? String,
              event == "payment_intent",
              let paymentUri = json["paymentUri"] as? String
        else {
            return
        }

        Task { @MainActor in
            do {
                try await app.handleScannedData(paymentUri)

                PaymentNavigationHelper.openPaymentSheet(
                    app: app,
                    currency: currency,
                    settings: settings,
                    sheetViewModel: sheets
                )
            } catch {
                app.toast(error)
            }
        }
    }
}
