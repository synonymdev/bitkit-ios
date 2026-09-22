@testable import Bitkit
import XCTest

final class PubkyContactLinkTests: XCTestCase {
    private let key = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"

    func testAcceptsRawPrefixedAndEncodedKeys() throws {
        for value in [String(key.dropFirst(5)), key, key.uppercased(), key.replacingOccurrences(of: "pubky", with: "%70ubky")] {
            let url = try XCTUnwrap(URL(string: "bitkit://contact?pubky=\(value)"))
            XCTAssertEqual(PubkyContactLink.publicKey(from: url), key)
        }
    }

    func testRejectsMalformedLinksAndNonKeyPayloads() throws {
        for link in [
            "https://contact?pubky=\(key)",
            "bitkit://other?pubky=\(key)",
            "bitkit://user@contact?pubky=\(key)",
            "bitkit://contact:123?pubky=\(key)",
            "bitkit://contact/path?pubky=\(key)",
            "bitkit://contact?pubky=\(key)#fragment",
            "bitkit://contact",
            "bitkit://contact?pubky=",
            "bitkit://contact?pubky=\(key)&pubky=\(key)",
            "bitkit://contact?pubky=\(key)&other=value",
            "bitkit://contact?pubky=\(key)extra",
            "bitkit://contact?pubky=invalid",
            "bitkit://contact?pubky=bitcoin%3Abc1example",
            "bitkit://contact?pubky=pubkyauth%3A%2F%2Fsignin_grant",
        ] {
            XCTAssertNil(try PubkyContactLink.publicKey(from: XCTUnwrap(URL(string: link))), link)
        }
    }

    func testDisabledPaykitIgnoresContactLinks() throws {
        let url = try XCTUnwrap(URL(string: "bitkit://contact?pubky=\(key)"))
        XCTAssertNil(try pubkyContactPublicKeyForRouting(from: url, isPaykitUIActive: false))
    }

    @MainActor
    func testMalformedContactLinkDoesNotWaitForPubkyReadiness() async throws {
        let app = AppViewModel(sheetViewModel: SheetViewModel(), navigationViewModel: NavigationViewModel())
        let url = try XCTUnwrap(URL(string: "bitkit://contact?pubky=invalid"))
        app.retainDeepLink(url)
        var handled = false
        await app.routePendingDeepLinkIfReady(true, pubkyContactsAreReady: false) { routedURL in
            handled = true
            XCTAssertNil(PubkyContactLink.publicKey(from: routedURL))
        }
        XCTAssertTrue(handled)
        XCTAssertNil(app.pendingDeepLinkURL)
    }

    @MainActor
    func testContactLinkSurvivesStartupAndContactLoadingErrorsUntilRecovery() async throws {
        let app = AppViewModel(sheetViewModel: SheetViewModel(), navigationViewModel: NavigationViewModel())
        let profile = PubkyProfileManager()
        let contacts = ContactsManager()
        let url = try XCTUnwrap(URL(string: "bitkit://contact?pubky=\(key)"))
        app.retainDeepLink(url)

        func routePendingLink() async {
            await app.routePendingDeepLinkIfReady(
                true,
                pubkyContactsAreReady: canRoutePubkyContactLink(
                    isPaykitUIActive: true,
                    isPubkyInitialized: profile.isInitialized,
                    hasPubkyIdentity: profile.publicKey != nil,
                    hasLoadedContacts: contacts.hasLoaded
                )
            ) { routedURL in
                XCTAssertEqual(routedURL, url)
            }
        }

        profile.initializationErrorMessage = "Network unavailable"
        await routePendingLink()
        XCTAssertEqual(app.pendingDeepLinkURL, url)

        profile.initializationErrorMessage = nil
        profile.isInitialized = true
        profile.publicKey = key
        contacts.loadErrorMessage = "Storage unavailable"
        await routePendingLink()
        XCTAssertEqual(app.pendingDeepLinkURL, url)

        contacts.loadErrorMessage = nil
        contacts.hasLoaded = true
        await routePendingLink()
        XCTAssertNil(app.pendingDeepLinkURL)
    }

    @MainActor
    func testContactLinkWaitsForUnlockAndContactsButNotLightningNodeAndUsesScannerRouting() async throws {
        let previous = UserDefaults.standard.object(forKey: PaykitFeatureFlags.uiEnabledKey)
        UserDefaults.standard.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
        defer { UserDefaults.standard.set(previous, forKey: PaykitFeatureFlags.uiEnabledKey) }
        let navigation = NavigationViewModel()
        let app = AppViewModel(sheetViewModel: SheetViewModel(), navigationViewModel: navigation)
        let scanner = ScannerManager()
        scanner.configure(app: app, navigation: navigation)
        let url = try XCTUnwrap(URL(string: "bitkit://contact?pubky=\(key)"))

        app.retainDeepLink(url)
        await app.routePendingDeepLinkIfReady(false, nodeIsRunning: false) { _ in
            XCTFail("Must wait for wallet readiness and unlock")
        }
        XCTAssertEqual(app.pendingDeepLinkURL, url)
        await app.routePendingDeepLinkIfReady(true, nodeIsRunning: true, pubkyContactsAreReady: false) { _ in
            XCTFail("Must retain contact links until identity and contacts finish loading, even when LDK starts")
        }
        XCTAssertEqual(app.pendingDeepLinkURL, url)
        await app.routePendingDeepLinkIfReady(true, nodeIsRunning: false) { url in
            guard let publicKey = PubkyContactLink.publicKey(from: url) else {
                return XCTFail("Expected a contact key")
            }
            await scanner.handleScan(publicKey, context: .main)
        }
        XCTAssertNil(app.pendingDeepLinkURL)
        XCTAssertEqual(navigation.currentRoute, .addContact(publicKey: key))
        await app.routePendingDeepLinkIfReady(true) { _ in XCTFail("Must not route twice") }
    }
}
