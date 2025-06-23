import SwiftUI
import WebKit

struct ShopMain: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var sheets: SheetViewModel

    let page: String

    @State private var webView: WKWebView?

    private var uri: String {
        let baseUrl = "https://embed.bitrefill.com"
        let paymentMethod = "bitcoin" // Payment method "bitcoin" gives a unified invoice
        let params = "?ref=\(Env.bitrefillRef)&paymentMethod=\(paymentMethod)&theme=dark&utm_source=\(Env.appName)"
        return "\(baseUrl)/\(page)/\(params)"
    }

    var body: some View {
        VStack(spacing: 0) {
            WebView(
                url: uri,
                webView: $webView,
                onMessage: handleMessage
            )
            .padding(.top, 16)
            .padding(.horizontal, 16)
        }
        .navigationTitle(localizedString("other__shop__main__nav_title"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .backToWalletButton()
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
                sheets.showSheet(.send, data: SendConfig(view: .confirm))
            } catch {
                app.toast(error)
            }
        }
    }
}

// MARK: - WebView Component

struct WebView: UIViewRepresentable {
    let url: String
    @Binding var webView: WKWebView?
    let onMessage: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "messageHandler")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0x14 / 255.0, green: 0x17 / 255.0, blue: 0x16 / 255.0, alpha: 1.0) // #141716
        webView.scrollView.backgroundColor = webView.backgroundColor
        webView.layer.cornerRadius = 8
        webView.clipsToBounds = true

        self.webView = webView

        if let url = URL(string: url) {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Updates handled by coordinator
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: WebView

        init(_ parent: WebView) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "messageHandler", let body = message.body as? String {
                parent.onMessage(body)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Inject JavaScript to capture postMessage events
            let script = """
                    window.addEventListener('message', function(event) {
                        window.webkit.messageHandlers.messageHandler.postMessage(JSON.stringify(event.data));
                    });
                """
            webView.evaluateJavaScript(script)
        }
    }
}
