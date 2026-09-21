import Foundation

enum ShopOrigin {
    static let rootHost = "bitrefill.com"
    static let paymentOrigin = "https://embed.bitrefill.com"
    private static let defaultHttpsPort = 443

    static func isAllowedHost(_ host: String?) -> Bool {
        guard var host = host?.lowercased() else { return false }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == rootHost || host.hasSuffix(".\(rootHost)")
    }

    static func isAllowed(_ url: URL?) -> Bool {
        guard let url else { return false }
        guard url.scheme?.lowercased() == "https" else { return false }
        return isAllowedHost(url.host)
    }

    static func isAllowedMessageSender(isMainFrame: Bool, scheme: String, host: String, port: Int) -> Bool {
        guard let expectedOrigin = URL(string: paymentOrigin),
              let expectedScheme = expectedOrigin.scheme,
              let expectedHost = expectedOrigin.host
        else {
            return false
        }
        return isMainFrame
            && scheme.lowercased() == expectedScheme
            && host.lowercased() == expectedHost
            && (port == 0 || port == defaultHttpsPort)
    }

    static func shouldRestrictNavigation(initialUrl: String) -> Bool {
        isAllowed(URL(string: initialUrl))
    }

    static func shouldAllowMainFrameNavigation(to url: URL?, initialUrl: String) -> Bool {
        guard shouldRestrictNavigation(initialUrl: initialUrl) else { return true }
        return isAllowed(url)
    }

    static var messageBridgeScript: String {
        """
        if (!window.__bitkitShopBridgeInstalled) {
            window.__bitkitShopBridgeInstalled = true;
            window.addEventListener('message', function(event) {
                if (event.origin !== '\(paymentOrigin)') return;
                window.webkit.messageHandlers.messageHandler.postMessage(JSON.stringify(event.data));
            });
        }
        """
    }
}
