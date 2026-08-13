import Foundation

enum ShopOrigin {
    static let rootHost = "bitrefill.com"

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

    static func shouldRestrictNavigation(initialUrl: String) -> Bool {
        isAllowed(URL(string: initialUrl))
    }

    static func shouldAllowMainFrameNavigation(to url: URL?, initialUrl: String) -> Bool {
        guard shouldRestrictNavigation(initialUrl: initialUrl) else { return true }
        return isAllowed(url)
    }

    static var messageBridgeScript: String {
        """
        window.addEventListener('message', function(event) {
            try {
                var originUrl = new URL(event.origin);
                if (originUrl.protocol !== 'https:') return;
                var host = originUrl.hostname.toLowerCase();
                if (host !== '\(rootHost)' && !host.endsWith('.\(rootHost)')) return;
            } catch (e) {
                return;
            }
            window.webkit.messageHandlers.messageHandler.postMessage(JSON.stringify(event.data));
        });
        """
    }
}
