import SwiftUI
import WebKit

/// A reusable WebView component for shop-related content with consistent styling
struct ShopWebView: UIViewRepresentable {
    let url: String
    var webView: Binding<WKWebView?>?
    var onMessage: ((String) -> Void)?

    init(url: String, webView: Binding<WKWebView?>? = nil, onMessage: ((String) -> Void)? = nil) {
        self.url = url
        self.webView = webView
        self.onMessage = onMessage
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Add message handler if onMessage callback is provided
        if onMessage != nil {
            configuration.userContentController.add(context.coordinator, name: "messageHandler")
        }

        let wkWebView = WKWebView(frame: .zero, configuration: configuration)
        wkWebView.navigationDelegate = context.coordinator
        wkWebView.uiDelegate = context.coordinator
        wkWebView.isOpaque = false
        wkWebView.backgroundColor = UIColor(red: 0x14 / 255.0, green: 0x17 / 255.0, blue: 0x16 / 255.0, alpha: 1.0) // #141716
        wkWebView.scrollView.backgroundColor = wkWebView.backgroundColor
        wkWebView.layer.cornerRadius = 18
        wkWebView.clipsToBounds = true

        webView?.wrappedValue = wkWebView

        if let url = URL(string: url) {
            wkWebView.load(URLRequest(url: url))
        }

        return wkWebView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Updates handled by coordinator
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        var parent: ShopWebView

        init(_ parent: ShopWebView) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "messageHandler", let body = message.body as? String else { return }
            guard ShopOrigin.isAllowed(message.webView?.url) else {
                Logger.warn(
                    "Rejected shop payment_intent from untrusted origin '\(message.webView?.url?.absoluteString ?? "")'",
                    context: "ShopWebView"
                )
                return
            }
            parent.onMessage?(body)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.targetFrame?.isMainFrame == false {
                decisionHandler(.allow)
                return
            }
            if ShopOrigin.shouldAllowMainFrameNavigation(
                to: navigationAction.request.url,
                initialUrl: parent.url
            ) {
                decisionHandler(.allow)
                return
            }
            Logger.warn(
                "Blocked shop navigation to untrusted origin '\(navigationAction.request.url?.absoluteString ?? "")'",
                context: "ShopWebView"
            )
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Inject JavaScript to capture postMessage events if message handler is configured
            if parent.onMessage != nil {
                webView.evaluateJavaScript(ShopOrigin.messageBridgeScript)
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard ShopOrigin.shouldAllowMainFrameNavigation(
                to: navigationAction.request.url,
                initialUrl: parent.url
            ) else {
                Logger.warn(
                    "Blocked shop window navigation to untrusted origin '\(navigationAction.request.url?.absoluteString ?? "")'",
                    context: "ShopWebView"
                )
                return nil
            }
            webView.load(navigationAction.request)
            return nil
        }
    }
}
