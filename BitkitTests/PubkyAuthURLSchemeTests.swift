@testable import Bitkit
import XCTest

final class PubkyAuthURLSchemeTests: XCTestCase {
    func testAppUsesUniqueBitkitSchemeInsteadOfSharedPubkyAuthScheme() throws {
        let urlTypes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }

        XCTAssertTrue(schemes.contains("bitkit"))
        XCTAssertFalse(schemes.contains("pubkyauth"))
    }

    func testAppQueriesPubkyRingSpecificOutboundURLScheme() throws {
        let schemes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String])

        XCTAssertTrue(schemes.contains("pubkyring"))
    }

    @MainActor
    func testAppDefersGatedPubkyAuthURLAndRoutesWatchOnlyConsentExactlyOnce() async throws {
        let hadPreviousPaykitUIValue = UserDefaults.standard.object(forKey: PaykitFeatureFlags.uiEnabledKey) != nil
        let previousPaykitUIValue = UserDefaults.standard.bool(forKey: PaykitFeatureFlags.uiEnabledKey)
        let previousSession = try? Keychain.loadString(key: .paykitSession)
        let previousSecretKey = try? Keychain.loadString(key: .pubkySecretKey)
        try Keychain.delete(key: .paykitSession)
        try Keychain.delete(key: .pubkySecretKey)
        try Keychain.saveString(key: .paykitSession, str: "test-session")
        try Keychain.saveString(key: .pubkySecretKey, str: "test-secret-key")
        UserDefaults.standard.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
        addTeardownBlock {
            try? Keychain.delete(key: .paykitSession)
            try? Keychain.delete(key: .pubkySecretKey)
            if let previousSession {
                try? Keychain.saveString(key: .paykitSession, str: previousSession)
            }
            if let previousSecretKey {
                try? Keychain.saveString(key: .pubkySecretKey, str: previousSecretKey)
            }
            if hadPreviousPaykitUIValue {
                UserDefaults.standard.set(previousPaykitUIValue, forKey: PaykitFeatureFlags.uiEnabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: PaykitFeatureFlags.uiEnabledKey)
            }
        }

        let sheets = SheetViewModel()
        let app = AppViewModel(sheetViewModel: sheets, navigationViewModel: NavigationViewModel())
        let url = try XCTUnwrap(URL(string: "bitkit://pubky-auth/setup?caps=\(PubkyAuthClaim.watchOnlyAccountCapabilities)" +
                "&relay=https%3A%2F%2Fhttprelay.pubky.app%2Finbox%2F" +
                "&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s&x-bitkit-claim=watch-only-account-v1"))
        var routeCount = 0

        app.retainDeepLink(url)
        for gate in ["startup", "restoration", "PIN"] {
            await app.routePendingDeepLinkIfReady(false) { _ in
                XCTFail("The \(gate) gate must retain the URL while main navigation is hidden")
            }
            XCTAssertEqual(app.pendingDeepLinkURL, url)
        }

        await app.routePendingDeepLinkIfReady(true) { routedURL in
            routeCount += 1
            do {
                try await app.handleScannedData(routedURL.absoluteString)
            } catch {
                XCTFail("The retained URL must route through the production scanner: \(error)")
            }
        }
        await app.routePendingDeepLinkIfReady(true) { _ in
            routeCount += 1
        }

        XCTAssertEqual(routeCount, 1)
        XCTAssertNil(app.pendingDeepLinkURL)
        XCTAssertEqual(sheets.activeSheetConfiguration?.id, .pubkyAuthApproval)
        let config = try XCTUnwrap(sheets.activeSheetConfiguration?.data as? PubkyAuthApprovalConfig)
        XCTAssertEqual(config.request.bitkitClaim, .watchOnlyAccountV1)
        XCTAssertTrue(config.authUrl.hasPrefix("pubkyauth://signin?"))

        sheets.hideSheet()
        let markerlessURL = "bitkit://pubky-auth/setup?caps=/pub/locks.app/:rw" +
            "&relay=https%3A%2F%2Fhttprelay.pubky.app%2Finbox%2F" +
            "&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s"
        try await app.handleScannedData(markerlessURL)

        XCTAssertNil(sheets.activeSheetConfiguration)

        let duplicateRelayURL = "bitkit://pubky-auth/setup?caps=\(PubkyAuthClaim.watchOnlyAccountCapabilities)" +
            "&relay=https%3A%2F%2Fa&relay=https%3A%2F%2Fb" +
            "&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s&x-bitkit-claim=watch-only-account-v1"
        try await app.handleScannedData(duplicateRelayURL)
        XCTAssertNil(sheets.activeSheetConfiguration)

        let duplicateSecretURL = "bitkit://pubky-auth/setup?caps=\(PubkyAuthClaim.watchOnlyAccountCapabilities)" +
            "&relay=https%3A%2F%2Fhttprelay.pubky.app%2Finbox%2F" +
            "&secret=first&secret=second&x-bitkit-claim=watch-only-account-v1"
        try await app.handleScannedData(duplicateSecretURL)
        XCTAssertNil(sheets.activeSheetConfiguration)
    }

    @MainActor
    func testNonNodeDeepLinksReleaseAfterStartupGatesWithoutWaitingForLDK() async throws {
        let app = AppViewModel(sheetViewModel: SheetViewModel(), navigationViewModel: NavigationViewModel())
        let pubkyURL = try XCTUnwrap(URL(string: "bitkit://pubky-auth/setup?caps=\(PubkyAuthClaim.watchOnlyAccountCapabilities)" +
                "&relay=https%3A%2F%2Fhttprelay.pubky.app%2Finbox%2F" +
                "&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s&x-bitkit-claim=watch-only-account-v1"))
        let httpURL = try XCTUnwrap(URL(string: "https://example.com/article"))
        let ringURL = try XCTUnwrap(URL(string: "bitkit://pubky-auth/success"))
        let malformedPubkyURL = try XCTUnwrap(URL(string: "bitkit://pubky-auth/setup"))
        let lightningSamRockURL = try XCTUnwrap(
            URL(string: "lightning:https://btcpay.example/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123")
        )
        let lnurlSamRockURL = try XCTUnwrap(
            URL(string: "lnurl:https://btcpay.example/plugins/store123/samrock/protocol?setup=btc-chain&otp=abc123")
        )
        let lightningURL = try XCTUnwrap(URL(string: "lightning:lnbc1example"))

        app.retainDeepLink(pubkyURL)
        await app.routePendingDeepLinkIfReady(true, nodeIsRunning: false) { routedURL in
            XCTAssertEqual(routedURL, pubkyURL)
        }
        XCTAssertNil(app.pendingDeepLinkURL)

        app.retainDeepLink(httpURL)
        await app.routePendingDeepLinkIfReady(true, nodeIsRunning: false) { routedURL in
            XCTAssertEqual(routedURL, httpURL)
        }
        XCTAssertNil(app.pendingDeepLinkURL)

        app.retainDeepLink(ringURL)
        await app.routePendingDeepLinkIfReady(true, nodeIsRunning: false) { routedURL in
            XCTAssertEqual(routedURL, ringURL)
        }
        XCTAssertNil(app.pendingDeepLinkURL)

        app.retainDeepLink(malformedPubkyURL)
        await app.routePendingDeepLinkIfReady(true, nodeIsRunning: false) { routedURL in
            XCTAssertEqual(routedURL, malformedPubkyURL)
        }
        XCTAssertNil(app.pendingDeepLinkURL)

        app.retainDeepLink(lightningSamRockURL)
        await app.routePendingDeepLinkIfReady(true, nodeIsRunning: false) { routedURL in
            XCTAssertEqual(routedURL, lightningSamRockURL)
        }
        XCTAssertNil(app.pendingDeepLinkURL)

        app.retainDeepLink(lnurlSamRockURL)
        await app.routePendingDeepLinkIfReady(true, nodeIsRunning: false) { routedURL in
            XCTAssertEqual(routedURL, lnurlSamRockURL)
        }
        XCTAssertNil(app.pendingDeepLinkURL)

        app.retainDeepLink(lightningURL)
        await app.routePendingDeepLinkIfReady(true, nodeIsRunning: false) { _ in
            XCTFail("URLs that need the node must stay pending until LDK is running")
        }
        XCTAssertEqual(app.pendingDeepLinkURL, lightningURL)

        await app.routePendingDeepLinkIfReady(true, nodeIsRunning: true) { routedURL in
            XCTAssertEqual(routedURL, lightningURL)
        }
        XCTAssertNil(app.pendingDeepLinkURL)
    }
}
