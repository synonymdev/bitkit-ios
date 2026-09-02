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
    }
}
