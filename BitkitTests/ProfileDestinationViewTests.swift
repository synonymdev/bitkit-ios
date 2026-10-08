@testable import Bitkit
import SwiftUI
import Vision
import XCTest

@MainActor
final class ProfileDestinationViewTests: XCTestCase {
    func testContactsWaitsForIdentityLookupThenShowsRecovery() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.removeObject(forKey: "pubky_profile_name")
        let manager = ContactsRecoveryProfileManager()
        manager.isInitialized = false
        manager.initializationErrorMessage = "offline"
        let app = AppViewModel()
        app.hasSeenContactsIntro = false
        let window = hostContacts(manager, app: app)
        defer { close(window) }

        await fulfillment(of: [manager.lookup.started], timeout: 3)
        let (_, pendingLabels) = try snapshot(window, name: "Contacts identity lookup")
        XCTAssertFalse(pendingLabels.contains(t("contacts__intro_add_contact")))
        XCTAssertFalse(pendingLabels.contains(t("profile__retry_load")))
        XCTAssertFalse(manager.didAttemptRecovery)

        manager.lookup.finish()
        await fulfillment(of: [manager.restoration.started], timeout: 3)
        try await assertLoadingScreen(window, name: "Contacts restoring saved identity")
        manager.restoration.finish()
        try await assertRetryScreen(window, name: "Contacts restoration failed")
        XCTAssertTrue(manager.didAttemptRecovery)
    }

    func testContactsPreservesAuthenticatedListAndAbsentIdentityOnboarding() async throws {
        snapshotAppDefaultsDomain()
        for authenticated in [false, true] {
            let manager = ContactsRecoveryProfileManager()
            manager.identityExists = false
            manager.authState = authenticated ? .authenticated : .idle
            manager.publicKey = authenticated ? "pubky_test_identity" : nil
            let app = AppViewModel()
            app.hasSeenContactsIntro = authenticated
            let window = hostContacts(manager, app: app)
            defer { close(window) }
            await fulfillment(of: [manager.lookup.started], timeout: 3)
            manager.lookup.finish()
            try await Task.sleep(for: .milliseconds(150))
            let (_, labels) = try snapshot(window, name: authenticated ? "Authenticated Contacts" : "Contacts onboarding")
            XCTAssertTrue(labels.contains(t(authenticated ? "common__search" : "contacts__intro_add_contact")), "\(labels)")
            XCTAssertFalse(manager.didAttemptRecovery)
        }
    }

    func testContactsIntroWaitsForLookupAndPreservesDestinations() async {
        snapshotAppDefaultsDomain()
        for (authenticated, savedIdentity, seenProfileIntro, destination) in [
            (false, true, false, Route.contacts),
            (false, true, true, .contacts),
            (true, true, true, .contacts),
            (false, false, false, .profileIntro),
            (false, false, true, .pubkyChoice),
        ] {
            let manager = ContactsRecoveryProfileManager()
            manager.identityExists = savedIdentity
            manager.authState = authenticated ? .authenticated : .idle
            manager.publicKey = authenticated ? "pubky_test_identity" : nil
            let app = AppViewModel()
            app.hasSeenContactsIntro = false
            app.hasSeenProfileIntro = seenProfileIntro
            let contacts = ContactsManager()
            let navigation = NavigationViewModel()
            navigation.path = [.contactsIntro]
            let task = Task {
                await ContactsIntroView.openContacts(app: app, navigation: navigation, pubkyProfile: manager, contactsManager: contacts)
            }
            await fulfillment(of: [manager.lookup.started], timeout: 3)
            XCTAssertEqual(navigation.path, [.contactsIntro])
            XCTAssertFalse(app.hasSeenContactsIntro)
            manager.lookup.finish()
            await task.value
            XCTAssertEqual(navigation.path, [.contactsIntro, destination])
            XCTAssertEqual(contacts.shouldOpenAddContactSheet, authenticated)
            XCTAssertTrue(app.hasSeenContactsIntro)
        }
    }

    func testContactsIntroDiscardsNavigationAfterLeavingOrCancellation() async {
        snapshotAppDefaultsDomain()
        for cancel in [false, true] {
            let manager = ContactsRecoveryProfileManager()
            let app = AppViewModel()
            app.hasSeenContactsIntro = false
            let navigation = NavigationViewModel()
            navigation.path = [.contactsIntro]
            let contacts = ContactsManager()
            let task = Task {
                await ContactsIntroView.openContacts(app: app, navigation: navigation, pubkyProfile: manager, contactsManager: contacts)
            }
            await fulfillment(of: [manager.lookup.started], timeout: 3)
            if cancel {
                task.cancel()
            } else {
                navigation.path = [.settings]
            }
            manager.lookup.finish()
            await task.value
            XCTAssertEqual(navigation.path, cancel ? [.contactsIntro] : [.settings])
            XCTAssertFalse(contacts.shouldOpenAddContactSheet)
            XCTAssertFalse(app.hasSeenContactsIntro)
        }
    }

    func testLeavingContactsDuringLookupDoesNotStartRecovery() async throws {
        snapshotAppDefaultsDomain()
        let manager = ContactsRecoveryProfileManager()
        let window = hostContacts(manager, app: AppViewModel())
        await fulfillment(of: [manager.lookup.started], timeout: 3)
        window.rootViewController = UIHostingController(rootView: Color.black)
        try await Task.sleep(for: .milliseconds(100))
        manager.lookup.finish()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(manager.didAttemptRecovery)
        close(window)
    }

    func testContactsRecoveryReturnsToOnboardingAfterIdentityIsRemoved() async throws {
        snapshotAppDefaultsDomain()
        let manager = ContactsRecoveryProfileManager()
        let app = AppViewModel()
        app.hasSeenProfileIntro = false
        let window = hostContacts(manager, app: app)
        defer { close(window) }
        await fulfillment(of: [manager.lookup.started], timeout: 3)
        manager.lookup.finish()
        await fulfillment(of: [manager.restoration.started], timeout: 3)
        manager.restoration.finish()
        try await assertRetryScreen(window, name: "Contacts before disconnect")

        manager.identityExists = false
        manager.authState = .idle
        try await Task.sleep(for: .milliseconds(100))
        let (_, labels) = try snapshot(window, name: "Contacts after disconnect")
        XCTAssertTrue(labels.contains(t("common__continue")), "\(labels)")
        XCTAssertFalse(labels.contains(t("profile__retry_load")))
    }

    func testDisconnectedSavedIdentityRendersProfileRetry() async throws {
        snapshotAppDefaultsDomain()
        let keys: [KeychainEntryType] = [.paykitSession, .pubkySecretKey]
        let savedValues = try keys.map { try Keychain.load(key: $0) }
        let savedReference = AdoptedPubkyReference.current
        let defaults = UserDefaults.standard
        defer {
            AdoptedPubkyReference.current = savedReference
            for (key, value) in zip(keys, savedValues) {
                if let value {
                    try? Keychain.upsert(key: key, data: value)
                } else {
                    try? Keychain.delete(key: key)
                }
            }
        }

        for source in ["local", "session", "ring", "cached"] {
            for key in keys {
                try Keychain.delete(key: key)
            }
            AdoptedPubkyReference.current = nil
            defaults.removeObject(forKey: "pubky_profile_name")
            switch source {
            case "local": try Keychain.upsert(key: .pubkySecretKey, data: Data("saved-key".utf8))
            case "session": try Keychain.upsert(key: .paykitSession, data: Data("saved-session".utf8))
            case "ring": AdoptedPubkyReference.current = (SharedPubkyKeychain.ringSourceApp, "saved-ring-key")
            default: defaults.set("Saved profile", forKey: "pubky_profile_name")
            }
            let manager = DisconnectedProfileManager()
            manager.isInitialized = true
            manager.sessionRestorationFailed = false
            let window = hostProfile(manager)
            defer { close(window) }
            try await Task.sleep(for: .milliseconds(100))
            let (_, labels) = try snapshot(window, name: "Disconnected profile - \(source)")
            XCTAssertTrue(labels.contains(t("profile__retry_load")), "Missing Retry for \(source): \(labels)")
            XCTAssertTrue(labels.contains(t("profile__sign_out")), "Missing Sign Out for \(source): \(labels)")
            XCTAssertTrue(manager.didAttemptRecovery, "Profile entry should attempt recovery for \(source)")
        }
    }

    func testProfileShowsLoadingWhileRestorationOrProfileFetchIsPending() async throws {
        snapshotAppDefaultsDomain()
        let savedReference = AdoptedPubkyReference.current
        AdoptedPubkyReference.current = nil
        defer { AdoptedPubkyReference.current = savedReference }
        UserDefaults.standard.set("Saved profile", forKey: "pubky_profile_name")
        let manager = SuspendedProfileManager()
        manager.isInitialized = true
        defer {
            manager.restoration.finish()
            manager.profileFetch.finish()
        }
        let window = hostProfile(manager)
        defer { close(window) }

        await fulfillment(of: [manager.restoration.started], timeout: 3)
        XCTAssertTrue(manager.isRestoringSession)
        try await assertLoadingScreen(window, name: "Restoring saved session")

        manager.restoration.finish()
        await fulfillment(of: [manager.profileFetch.started], timeout: 3)
        XCTAssertTrue(manager.isLoadingProfile)
        try await assertLoadingScreen(window, name: "Fetching profile")

        manager.profileFetch.finish()
        try await assertRetryScreen(window, name: "Recovery failed")
        XCTAssertFalse(manager.isRestoringSession)

        // Automatic recovery must also update an already visible Retry screen.
        manager.restoration = ProfileOperationGate(name: "Automatic restoration")
        let recovery = Task {
            await (manager as PubkyProfileManager).restoreSessionIfNeeded()
        }
        defer { recovery.cancel() }
        await fulfillment(of: [manager.restoration.started], timeout: 3)
        XCTAssertTrue(manager.isRestoringSession)
        try await assertLoadingScreen(window, name: "Automatic retry in progress")
        manager.restoration.finish()
        await recovery.value
        XCTAssertFalse(manager.isRestoringSession)
        try await assertRetryScreen(window, name: "Automatic retry failed")
    }

    func testDeferredSessionDisplaysPublicProfileWithoutAuthenticating() async throws {
        snapshotAppDefaultsDomain()
        let keys: [KeychainEntryType] = [.pubkySecretKey, .paykitSession]
        let savedValues = try keys.map { try Keychain.load(key: $0) }
        let savedReference = AdoptedPubkyReference.current
        defer {
            AdoptedPubkyReference.current = savedReference
            for (key, value) in zip(keys, savedValues) {
                if let value { try? Keychain.upsert(key: key, data: value) }
                else { try? Keychain.delete(key: key) }
            }
        }
        AdoptedPubkyReference.current = nil
        let secret = String(repeating: "01", count: 32)
        let publicKey = try PubkyProfileManager.publicKeyFromSecretKey(secret)
        try Keychain.upsert(key: .pubkySecretKey, data: Data(secret.utf8))
        let profile = PubkyProfile(
            publicKey: publicKey,
            name: "Saved public profile",
            bio: "Public biography",
            imageUrl: nil,
            links: [],
            tags: ["public-tag"],
            status: nil
        )
        let response = ProfileResponse(profile: profile)
        let manager = DeferredProfileManager(remoteProfileResolver: { _ in try await response.resolve() })
        await manager.initialize { .restorationDeferred }
        await manager.loadProfile()
        let navigation = NavigationViewModel()
        let window = hostProfile(manager, navigation: navigation)
        let pasteboard = UIPasteboard.general.string
        defer {
            close(window)
            UIPasteboard.general.string = pasteboard
        }
        try await Task.sleep(for: .milliseconds(150))

        let (_, labels) = try snapshot(window, name: "Public profile while private state reconnects")
        XCTAssertTrue(labels.joined(separator: " ").contains(profile.name.uppercased()), "\(labels)")
        XCTAssertTrue(labels.contains(profile.bio), "\(labels)")
        XCTAssertFalse(labels.contains(t("profile__empty_state")), "\(labels)")

        try await assertReadOnlyControls(window, navigation: navigation)
        for id in ["ProfileCopy", "ProfileQRCode"] {
            UIPasteboard.general.string = nil
            XCTAssertTrue(try element(id, in: window).accessibilityActivate())
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(UIPasteboard.general.string, publicKey, id)
        }

        let scroll = try XCTUnwrap(scrollView(in: XCTUnwrap(window.rootViewController?.view)))
        scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        let (_, footerLabels) = try snapshot(window, name: "Read-only profile disconnect")
        XCTAssertTrue(footerLabels.contains(t("profile__sign_out")), "\(footerLabels)")
        XCTAssertNil(manager.profile)
        XCTAssertNil(manager.publicKey)
        XCTAssertNil(manager.currentSession)

        let disconnectGate = ProfileOperationGate(name: "Read-only disconnect")
        defer { disconnectGate.finish() }
        let disconnect = Task {
            try await manager.signOut {
                disconnectGate.started.fulfill()
                for await _ in disconnectGate.stream {}
                throw PubkyServiceError.sessionNotActive
            }
        }
        await fulfillment(of: [disconnectGate.started], timeout: 3)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(accessibilityElements(in: window).contains { accessibilityIdentifier($0) == "ProfileViewName" })
        disconnectGate.finish()
        do {
            try await disconnect.value
            XCTFail("Disconnect should fail without an active session")
        } catch PubkyServiceError.sessionNotActive {}
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(accessibilityElements(in: window).contains { accessibilityIdentifier($0) == "ProfileViewName" })
        XCTAssertEqual(manager.publicKeyForDisplay, publicKey)

        await response.setProfile(nil)
        await manager.initialize { .restored(publicKey: publicKey) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(manager.currentSession)
        XCTAssertNil(manager.profile)
        XCTAssertEqual(manager.profileForDisplay?.name, profile.name)
        try await assertReadOnlyControls(window, navigation: navigation)

        for nextProfile in [nil, profile] {
            await response.setProfile(nextProfile)
            let retryGate = await response.holdNextRequest()
            defer { retryGate.finish() }
            let retry = try element("ProfileRetry", in: window)
            XCTAssertFalse(retry.accessibilityTraits.contains(.notEnabled))
            XCTAssertTrue(retry.accessibilityActivate())
            await fulfillment(of: [retryGate.started], timeout: 3)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(try element("ProfileRetry", in: window).accessibilityTraits.contains(.notEnabled))
            XCTAssertEqual(manager.profileForDisplay?.name, profile.name)
            try await assertReadOnlyControls(window, navigation: navigation)
            retryGate.finish()
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(manager.profile != nil, nextProfile != nil)
        }
        XCTAssertNotNil(manager.profile)
        for id in ["ProfileRetry", "ProfileSignOut"] {
            XCTAssertFalse(accessibilityElements(in: window).contains { accessibilityIdentifier($0) == id })
        }
        XCTAssertFalse(try element("ProfileEdit", in: window).accessibilityTraits.contains(.notEnabled))
        XCTAssertFalse(try element("ProfileAddTag", in: window).accessibilityTraits.contains(.notEnabled))
        XCTAssertNotNil(try element("Tag-public-tag-delete", in: window))
        XCTAssertTrue(try element("ProfileEdit", in: window).accessibilityActivate())
        XCTAssertEqual(navigation.path, [.editProfile])
    }

    private func assertReadOnlyControls(_ window: UIWindow, navigation: NavigationViewModel) async throws {
        let identifiers = ["ProfileEdit", "ProfileAddTag"]
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            window.layoutIfNeeded()
            let available = Set(accessibilityElements(in: window).compactMap(accessibilityIdentifier))
            if available.isSuperset(of: identifiers) { break }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline

        for id in identifiers {
            let control = try element(id, in: window)
            XCTAssertTrue(control.accessibilityTraits.contains(.notEnabled), id)
            _ = control.accessibilityActivate()
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(navigation.path.isEmpty)
        XCTAssertNil(window.rootViewController?.presentedViewController)
        XCTAssertFalse(accessibilityElements(in: window)
            .contains { accessibilityIdentifier($0) == "Tag-public-tag-delete" })
    }

    private func element(_ id: String, in window: UIWindow) throws -> NSObject {
        let elements = accessibilityElements(in: window)
        return try XCTUnwrap(
            elements.first { accessibilityIdentifier($0) == id },
            "Missing \(id); available: \(elements.compactMap(accessibilityIdentifier).sorted())"
        )
    }

    private func accessibilityIdentifier(_ element: NSObject) -> String? {
        guard element.responds(to: NSSelectorFromString("accessibilityIdentifier")) else { return nil }
        return element.value(forKey: "accessibilityIdentifier") as? String
    }

    private func accessibilityElements(in root: NSObject) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        func walk(_ node: NSObject) -> [NSObject] {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return [] }
            var children = (node as? UIView)?.subviews.map { $0 as NSObject } ?? []
            children += node.accessibilityElements?.compactMap { $0 as? NSObject } ?? []
            children += node.automationElements?.compactMap { $0 as? NSObject } ?? []
            let count = node.accessibilityElementCount()
            if count > 0, count < 1000 {
                children += (0 ..< count).compactMap { node.accessibilityElement(at: $0) as? NSObject }
            }
            return [node] + children.flatMap(walk)
        }
        return walk(root)
    }

    private func hostProfile(_ manager: PubkyProfileManager, navigation: NavigationViewModel? = nil) -> UIWindow {
        let view = ProfileDestinationView(hasSeenIntro: true)
            .environmentObject(manager)
            .environmentObject(AppViewModel())
            .environmentObject(navigation ?? NavigationViewModel())
            .environmentObject(ContactsManager())
            .preferredColorScheme(.dark)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.rootViewController?.view.layoutIfNeeded()
        return window
    }

    private func hostContacts(_ manager: PubkyProfileManager, app: AppViewModel) -> UIWindow {
        let view = ContactsDestinationView()
            .environmentObject(manager)
            .environmentObject(app)
            .environmentObject(NavigationViewModel())
            .environmentObject(ContactsViewTestManager() as ContactsManager)
            .preferredColorScheme(.dark)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.rootViewController?.view.layoutIfNeeded()
        return window
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private func snapshot(_ window: UIWindow, name: String) throws -> (UIImage, [String]) {
        let view = try XCTUnwrap(window.rootViewController?.view)
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (image, request.results?.compactMap { $0.topCandidates(1).first?.string } ?? [])
    }

    private func assertLoadingScreen(_ window: UIWindow, name: String) async throws {
        // ActivityIndicator fades in over one second. Inspect its rendered pixels after that animation.
        try await Task.sleep(for: .milliseconds(1200))
        let (image, labels) = try snapshot(window, name: name)
        XCTAssertFalse(labels.contains(t("profile__retry_load")), "Retry visible during \(name): \(labels)")
        XCTAssertFalse(labels.contains(t("profile__sign_out")), "Disconnect visible during \(name): \(labels)")
        let cgImage = try XCTUnwrap(image.cgImage)
        // This center strip excludes navigation and contains the only content in ProfileLoading: its spinner.
        let center = CGRect(
            x: CGFloat(cgImage.width) * 0.4,
            y: CGFloat(cgImage.height) * 0.3,
            width: CGFloat(cgImage.width) * 0.2,
            height: CGFloat(cgImage.height) * 0.4
        )
        let crop = try XCTUnwrap(cgImage.cropping(to: center))
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        XCTAssertGreaterThan(pixels.filter { $0 > 64 }.count, 50, "ProfileLoading spinner missing during \(name)")
    }

    private func assertRetryScreen(_ window: UIWindow, name: String) async throws {
        try await Task.sleep(for: .milliseconds(100))
        let (_, labels) = try snapshot(window, name: name)
        XCTAssertTrue(labels.contains(t("profile__retry_load")), "Missing Retry after \(name): \(labels)")
        XCTAssertTrue(labels.contains(t("profile__sign_out")), "Missing Disconnect after \(name): \(labels)")
    }
}

@MainActor
private final class ContactsViewTestManager: ContactsManager {
    override func loadContacts(for publicKey: String) async throws {}
}

@MainActor
private final class ContactsRecoveryProfileManager: PubkyProfileManager {
    var identityExists = true
    var didAttemptRecovery = false
    let lookup = ProfileOperationGate(name: "Saved identity lookup")
    let restoration = ProfileOperationGate(name: "Contacts session restoration")

    override var hasExistingIdentity: Bool {
        identityExists
    }

    override func hasExistingIdentityForNavigation(hasStoredIdentity: @escaping @Sendable () throws -> Bool) async -> Bool {
        lookup.started.fulfill()
        for await _ in lookup.stream {}
        return identityExists
    }

    override func restoreSessionIfNeeded(
        hasStoredIdentity: () throws -> Bool,
        initializeSession: @escaping @Sendable () async throws -> SessionInitializationResult
    ) async {
        didAttemptRecovery = true
        let gate = restoration
        await super.restoreSessionIfNeeded(hasStoredIdentity: { true }) {
            gate.started.fulfill()
            for await _ in gate.stream {}
            return .restorationFailed
        }
    }

    override func loadProfile() async {}
}

@MainActor
private final class DeferredProfileManager: PubkyProfileManager {
    override func restoreSessionIfNeeded(
        hasStoredIdentity: () throws -> Bool,
        initializeSession: @escaping @Sendable () async throws -> SessionInitializationResult
    ) async {
        await super.restoreSessionIfNeeded(hasStoredIdentity: { true }) { .restorationDeferred }
    }
}

@MainActor
private final class DisconnectedProfileManager: PubkyProfileManager {
    var didAttemptRecovery = false

    override func restoreSessionIfNeeded(
        hasStoredIdentity: () throws -> Bool,
        initializeSession: @escaping @Sendable () async throws -> SessionInitializationResult
    ) async {
        didAttemptRecovery = true
    }

    override func loadProfile() async {}
}

private struct ProfileOperationGate {
    let started: XCTestExpectation
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(name: String) {
        started = XCTestExpectation(description: name)
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    func finish() {
        continuation.finish()
    }
}

private actor ProfileResponse {
    var profile: PubkyProfile?
    private var gate: ProfileOperationGate?

    init(profile: PubkyProfile) {
        self.profile = profile
    }

    func setProfile(_ profile: PubkyProfile?) {
        self.profile = profile
    }

    func holdNextRequest() -> ProfileOperationGate {
        let gate = ProfileOperationGate(name: "Profile retry")
        self.gate = gate
        return gate
    }

    func resolve() async throws -> PubkyProfile {
        if let gate {
            self.gate = nil
            gate.started.fulfill()
            for await _ in gate.stream {}
        }
        guard let profile else { throw URLError(.notConnectedToInternet) }
        return profile
    }
}

@MainActor
private final class SuspendedProfileManager: PubkyProfileManager {
    var restoration = ProfileOperationGate(name: "Session restoration")
    var profileFetch = ProfileOperationGate(name: "Profile fetch")

    override func restoreSessionIfNeeded(
        hasStoredIdentity: () throws -> Bool,
        initializeSession: @escaping @Sendable () async throws -> SessionInitializationResult
    ) async {
        let gate = restoration
        await super.restoreSessionIfNeeded(hasStoredIdentity: { true }) {
            gate.started.fulfill()
            for await _ in gate.stream {}
            throw PubkyServiceError.authFailed("offline")
        }
    }

    override func loadProfile() async {
        isLoadingProfile = true
        defer { isLoadingProfile = false }
        let gate = profileFetch
        gate.started.fulfill()
        for await _ in gate.stream {}
    }
}
