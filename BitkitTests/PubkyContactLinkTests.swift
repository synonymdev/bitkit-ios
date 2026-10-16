@testable import Bitkit
import XCTest

final class PubkyContactLinkTests: XCTestCase {
    private let key = "pubky3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"

    @MainActor
    private final class RecoveringContactsManager: ContactsManager {
        private(set) var loadAttempts = 0

        override func loadContacts(for publicKey: String) async throws {
            loadAttempts += 1
            loadErrorMessage = nil
            hasLoaded = true
        }
    }

    @MainActor
    private final class SuspendedContactsManager: ContactsManager {
        let started = XCTestExpectation(description: "Contact preparation started")
        var finish: CheckedContinuation<Void, Never>?

        override func refreshContacts(for publicKey: String) async throws {
            await withCheckedContinuation {
                finish = $0
                started.fulfill()
            }
            throw PubkyServiceError.sessionNotActive
        }
    }

    @MainActor
    private final class SavedContactsManager: ContactsManager {
        var savedContact: PubkyContact?
        private(set) var refreshAttempts = 0

        override func refreshContacts(for publicKey: String) async throws {
            refreshAttempts += 1
            contacts = savedContact.map { [$0] } ?? []
            hasLoaded = true
        }
    }

    func testAcceptsRawPrefixedAndEncodedKeys() throws {
        for value in [String(key.dropFirst(5)), key, key.uppercased(), key.replacingOccurrences(of: "pubky", with: "%70ubky")] {
            let url = try XCTUnwrap(URL(string: "bitkit://contact?pubky=\(value)"))
            XCTAssertEqual(PubkyContactLink.publicKey(from: url), key)
        }
    }

    @MainActor
    func testDeletedContactDoesNotDismissANewerRoute() {
        let navigation = NavigationViewModel()
        for route: Route in [.contactDetail(publicKey: key), .editContact(publicKey: key), .contactSaved(publicKey: key)] {
            navigation.path = [.contacts, route]
            navigation.returnToContactsAfterRemoving(publicKey: key)
            XCTAssertEqual(navigation.path, [.contacts])

            navigation.navigate(.addContact(publicKey: key))
            let addPath = navigation.path
            navigation.returnToContactsAfterRemoving(publicKey: key)
            XCTAssertEqual(navigation.path, addPath)

            navigation.path = [.contacts, route, .addContact(publicKey: key)]
            navigation.returnToContactsAfterRemoving(publicKey: key)
            XCTAssertEqual(navigation.path, [.contacts, .addContact(publicKey: key)])

            navigation.path = [route]
            navigation.returnToContactsAfterRemoving(publicKey: key)
            XCTAssertEqual(navigation.path, [.contacts])
        }
        let otherKey = "pubky" + String(repeating: "y", count: 52)
        for route: Route in [.contactDetail(publicKey: otherKey), .contactSaved(publicKey: otherKey), .settings] {
            navigation.path = [.contacts, route]
            navigation.returnToContactsAfterRemoving(publicKey: key)
            XCTAssertEqual(navigation.path, [.contacts, route])
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
                    hasLoadedContacts: contacts.hasLoaded,
                    hasSignedInIdentity: profile.isAuthenticated
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
    func testContactLinkDistinguishesSignedOutFromRestoringIdentity() async throws {
        snapshotAppDefaultsDomain()
        for restoringSession in [false, true] {
            let navigation = NavigationViewModel()
            let app = AppViewModel(sheetViewModel: SheetViewModel(), navigationViewModel: navigation)
            let profile = PubkyProfileManager()
            let contacts = ContactsManager(contactRecords: { throw PubkyServiceError.sessionNotActive })
            let url = try XCTUnwrap(URL(string: "bitkit://contact?pubky=\(key)"))
            app.retainDeepLink(url)
            profile.isInitialized = true
            let started = XCTestExpectation(description: "Session restoration started")
            let (gate, finish) = AsyncStream<Void>.makeStream()
            let restoration = Task {
                guard restoringSession else { return }
                await profile.restoreSessionIfNeeded(hasStoredIdentity: { true }) {
                    started.fulfill()
                    for await _ in gate {}
                    return .restorationDeferred
                }
            }
            if restoringSession { await fulfillment(of: [started], timeout: 2) }
            XCTAssertEqual(profile.isRestoringSession, restoringSession)
            let ready = try await preparePubkyContactLink(profile: profile, contacts: contacts, hasStoredIdentity: { restoringSession })
            XCTAssertEqual(ready, !restoringSession)
            await app.routePendingDeepLinkIfReady(
                true,
                pubkyContactsAreReady: ready && canRoutePubkyContactLink(
                    isPaykitUIActive: true,
                    isPubkyInitialized: profile.isInitialized,
                    hasLoadedContacts: contacts.hasLoaded,
                    hasSignedInIdentity: profile.isAuthenticated
                )
            ) { routedURL in
                guard let publicKey = PubkyContactLink.publicKey(from: routedURL) else { return XCTFail("Expected contact key") }
                XCTAssertTrue(routePublicContactIfSignedOut(
                    publicKey: publicKey, profile: profile, navigation: navigation, hasStoredIdentity: { restoringSession }
                ))
            }
            XCTAssertEqual(app.pendingDeepLinkURL, restoringSession ? url : nil)
            XCTAssertEqual(navigation.path, restoringSession ? [] : [.addContact(publicKey: key)])
            XCTAssertFalse(contacts.hasLoaded)
            XCTAssertFalse(profile.isAuthenticated)
            XCTAssertNil(profile.currentSession)
            if !restoringSession {
                await app.routePendingDeepLinkIfReady(true) { _ in XCTFail("Must not route twice") }
            }
            finish.finish()
            await restoration.value
            if restoringSession {
                let deferredReady = try await preparePubkyContactLink(profile: profile, contacts: contacts, hasStoredIdentity: { true })
                XCTAssertFalse(deferredReady)
                XCTAssertFalse(routePublicContactIfSignedOut(
                    publicKey: key, profile: profile, navigation: navigation, hasStoredIdentity: { true }
                ))
            }
            profile.publicKey = key
            XCTAssertFalse(routePublicContactIfSignedOut(publicKey: key, profile: profile, navigation: navigation))
            XCTAssertEqual(navigation.path, restoringSession ? [] : [.addContact(publicKey: key)])
        }
    }

    @MainActor
    func testStoredIdentityContactLinkRoutesSavedContactAfterRecovery() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
        for restorationResult: PubkyProfileManager.SessionInitializationResult in [.restorationDeferred, .restorationFailed] {
            let navigation = NavigationViewModel()
            let app = AppViewModel(sheetViewModel: SheetViewModel(), navigationViewModel: navigation)
            let profile = PubkyProfileManager()
            let contacts = SavedContactsManager()
            contacts.savedContact = PubkyContact(publicKey: key, profile: .placeholder(publicKey: key))
            let scanner = ScannerManager()
            scanner.configure(app: app, contactsManager: contacts, navigation: navigation, pubkyProfile: profile)
            let url = try XCTUnwrap(URL(string: "bitkit://contact?pubky=\(key)"))
            app.retainDeepLink(url)
            await profile.initialize { restorationResult }
            XCTAssertTrue(profile.isInitialized)
            XCTAssertFalse(profile.isRestoringSession)
            XCTAssertFalse(profile.isAuthenticated)

            func routePendingLink(hasStoredIdentity: () throws -> Bool) async throws {
                let ready = try await preparePubkyContactLink(profile: profile, contacts: contacts, hasStoredIdentity: hasStoredIdentity)
                await app.routePendingDeepLinkIfReady(true, pubkyContactsAreReady: ready) { routedURL in
                    guard let publicKey = PubkyContactLink.publicKey(from: routedURL) else { return XCTFail("Expected contact key") }
                    if !routePublicContactIfSignedOut(
                        publicKey: publicKey, profile: profile, navigation: navigation, hasStoredIdentity: hasStoredIdentity
                    ) {
                        await scanner.handleScan(publicKey, context: .main)
                    }
                }
            }

            for unreadableCredentials in [false, true] {
                try await routePendingLink {
                    if unreadableCredentials { throw PubkyServiceError.sessionNotActive }
                    return true
                }
                XCTAssertEqual(app.pendingDeepLinkURL, url)
                XCTAssertEqual(navigation.path, [])
                XCTAssertEqual(contacts.refreshAttempts, 0)
                XCTAssertNil(contacts.loadErrorMessage)
                XCTAssertFalse(routePublicContactIfSignedOut(
                    publicKey: key, profile: profile, navigation: navigation,
                    hasStoredIdentity: {
                        if unreadableCredentials { throw PubkyServiceError.sessionNotActive }
                        return true
                    }
                ))
            }

            profile.publicKey = "pubky" + String(repeating: "y", count: 52)
            profile.authState = .authenticated
            try await routePendingLink { true }
            XCTAssertNil(app.pendingDeepLinkURL)
            XCTAssertEqual(navigation.path, [.contactDetail(publicKey: key)])
            XCTAssertEqual(contacts.refreshAttempts, 1)
            await app.routePendingDeepLinkIfReady(true) { _ in XCTFail("Must not route twice") }
        }
    }

    @MainActor
    func testSignedOutContactPreparationDoesNotReadPrivateContacts() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.set("Cached profile without credentials", forKey: "pubky_profile_name")
        let profile = PubkyProfileManager()
        profile.isInitialized = true
        XCTAssertNotNil(profile.cachedName)
        let contacts = ContactsManager(contactRecords: {
            throw PubkyServiceError.sessionNotActive
        })
        let ready = try await preparePubkyContactLink(profile: profile, contacts: contacts, hasStoredIdentity: { false })
        XCTAssertTrue(ready)
        XCTAssertFalse(contacts.hasLoaded)
        XCTAssertNil(contacts.loadErrorMessage)
        let navigation = NavigationViewModel()
        XCTAssertTrue(routePublicContactIfSignedOut(
            publicKey: key, profile: profile, navigation: navigation, hasStoredIdentity: { false }
        ))
        XCTAssertEqual(navigation.path, [.addContact(publicKey: key)])
        XCTAssertFalse(profile.isAuthenticated)
    }

    @MainActor
    func testContactPreparationDropsErrorsAfterSessionChangeOrCancellation() async throws {
        for cancel in [false, true] {
            let profile = PubkyProfileManager()
            profile.isInitialized = true
            profile.publicKey = key
            profile.authState = .authenticated
            let contacts = SuspendedContactsManager()
            let preparation = Task { try await preparePubkyContactLink(profile: profile, contacts: contacts) }
            await fulfillment(of: [contacts.started], timeout: 2)
            if cancel {
                preparation.cancel()
            } else {
                profile.publicKey = "pubky" + String(repeating: "y", count: 52)
            }
            contacts.finish?.resume()
            let ready = try await preparation.value
            XCTAssertFalse(ready)
        }
    }

    @MainActor
    func testContactPreloadRetriesAfterInFlightLoadFails() async throws {
        let contacts = RecoveringContactsManager()
        contacts.isLoading = true

        let loadTask = Task {
            try await contacts.loadContactsIfNeeded(for: key)
        }

        await Task.yield()
        XCTAssertEqual(contacts.loadAttempts, 0)

        contacts.loadErrorMessage = "Initial load failed"
        contacts.isLoading = false

        try await loadTask.value
        XCTAssertEqual(contacts.loadAttempts, 1)
        XCTAssertTrue(contacts.hasLoaded)
        XCTAssertNil(contacts.loadErrorMessage)
    }

    @MainActor
    func testContactPreloadStopsWaitingWhenTaskIsCancelled() async {
        let contacts = RecoveringContactsManager()
        contacts.isLoading = true

        let loadTask = Task {
            try await contacts.loadContactsIfNeeded(for: key)
        }

        await Task.yield()
        loadTask.cancel()

        do {
            try await loadTask.value
            XCTFail("Expected contact preload to stop after cancellation")
        } catch is CancellationError {
            XCTAssertEqual(contacts.loadAttempts, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testCancelledContactPreparationDoesNotRoutePendingLink() async {
        var finishPreparation: CheckedContinuation<Void, Never>?
        var didRoute = false

        let handlingTask = Task {
            await prepareAndRoutePendingDeepLink {
                await withCheckedContinuation { continuation in
                    finishPreparation = continuation
                }
            } routing: {
                didRoute = true
            }
        }

        while finishPreparation == nil {
            await Task.yield()
        }
        handlingTask.cancel()
        finishPreparation?.resume()
        await handlingTask.value

        XCTAssertFalse(didRoute)
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
