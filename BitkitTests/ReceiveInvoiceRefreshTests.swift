@testable import Bitkit
import XCTest

@MainActor
final class ReceiveInvoiceRefreshTests: XCTestCase {
    private var stored: [(String, Any?)] = []

    override func setUp() {
        super.setUp()
        stored = [
            "bolt11", "bip21", "onchainAddress", PublicPaykitService.publishingEnabledKey,
            PublicPaykitService.cleanupPendingKey, PaykitFeatureFlags.uiEnabledKey,
            "publicPaykitBolt11", "publicPaykitBolt11PaymentHash", "publicPaykitBolt11ExpiresAt",
            PublicPaykitService.lightningPaymentOptionEnabledKey,
            PrivatePaykitService.publishingEnabledKey,
        ].map { (
            $0,
            UserDefaults.standard.object(forKey: $0)
        ) }
        for (key, _) in stored {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for (key, value) in stored {
            UserDefaults.standard.set(value, forKey: key)
        }
        super.tearDown()
    }

    func testOlderRefreshCannotReplaceNewerInvoiceOrMixItsAmount() async throws {
        let wallet = GatedReceiveWallet()
        wallet.invoiceAmountSats = 1000
        wallet.invoiceNote = "older"
        let older = Task { try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false) }
        await fulfillment(of: [wallet.olderStarted], timeout: 5)
        wallet.invoiceAmountSats = 2000
        wallet.invoiceNote = "newer"
        try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false)
        wallet.releaseOlderInvoice()
        try await older.value
        XCTAssertEqual(wallet.bolt11, "ln-newer")
        XCTAssertTrue(wallet.bip21.contains("lightning=ln-newer"))
        XCTAssertTrue(wallet.bip21.contains("amount=0.00002"))
        XCTAssertTrue(wallet.bip21.contains("message=newer"))
        XCTAssertTrue(wallet.hasCoherentReceiveInvoice)
        XCTAssertFalse(wallet.isReceiveInvoiceUpdating)
    }

    func testAutomaticPublicationCannotRestoreEndpointsAfterDeletionRemoval() async throws {
        for route in AutomaticPublicationRoute.allCases {
            let (profile, wallet) = publicationWallet(route: route)
            let preparation = PublicationGate("Endpoint preparation")
            let revocation = PublicationGate("Removal completed, revocation held")
            var endpoints = ["ln-old"]
            wallet.beforePublicEndpointRefresh = {
                wallet.beforePublicEndpointRefresh = nil
                await preparation.wait()
            }
            wallet.applyPublicEndpoints = { endpoints = $0.map(\.value) }
            let publication = Task { try await route.refresh(wallet) }
            await fulfillment(of: [preparation.started], timeout: 5)
            let deletion = Task {
                try await profile.performProfileDeletion {
                    try await PublicPaykitService.syncPublishedEndpoints(
                        publish: false, buildEndpoints: { [] }, syncApp: {},
                        applyEndpoints: { endpoints = $0.map(\.value) }
                    )
                    await revocation.wait()
                }
            }
            await fulfillment(of: [revocation.started], timeout: 5)
            XCTAssertTrue(endpoints.isEmpty)
            preparation.release()
            try await publication.value
            XCTAssertTrue(endpoints.isEmpty, "\(route) restored removed endpoints")
            XCTAssertEqual(wallet.hasCoherentReceiveInvoice, true)
            revocation.release()
            try await deletion.value
            XCTAssertFalse(profile.isDeletingProfile)
        }
    }

    func testForcedChannelRefreshSurvivesFailedDeletionAndPublicationRetry() async throws {
        let (profile, wallet) = publicationWallet(route: .channelUsable)
        wallet.replaceEmptyPublicInvoice = true
        var published: [String] = []
        do {
            try await profile.performProfileDeletion {
                await wallet.refreshPaykitEndpointsAfterChannelAvailabilityChanged(reason: "test", forceRefreshLightning: true)
                XCTAssertTrue(wallet.publicPaykitBolt11.isEmpty)
                XCTAssertTrue(PublicPaykitService.isCleanupPending)
                throw PublicPaykitError.publicationFailed
            }
        } catch PublicPaykitError.publicationFailed {}
        let session = try XCTUnwrap(profile.automaticPaykitSession)
        do {
            try await PublicPaykitService.syncCurrentPublishedEndpoints(
                wallet: wallet, isSessionCurrent: { profile.automaticPaykitSession == session }, syncApp: {},
                applyEndpoints: { _ in throw PublicPaykitError.publicationFailed }
            )
            XCTFail("Expected publication failure")
        } catch PublicPaykitError.publicationFailed {}
        XCTAssertTrue(PublicPaykitService.isCleanupPending)
        try await PublicPaykitService.syncCurrentPublishedEndpoints(
            wallet: wallet, isSessionCurrent: { profile.automaticPaykitSession == session }, syncApp: {},
            applyEndpoints: { published = $0.map(\.value) }
        )
        XCTAssertEqual(published, ["ln-current"])
        XCTAssertFalse(PublicPaykitService.isCleanupPending)
    }

    func testStartupChannelRefreshSurvivesRestorationAndPublicationRetry() async throws {
        snapshotAppDefaultsDomain()
        let owner = "pubky" + String(repeating: "y", count: 52)
        enum FirstPublication: CaseIterable { case skipped, preparationFailed, publicationFailed }
        for restoration in [PubkyProfileManager.SessionInitializationResult.restored(publicKey: owner), .restorationDeferred, .restorationFailed] {
            for firstPublication in FirstPublication.allCases {
                AdoptedPubkyReference.current = ("startup-test", owner)
                let profile = StartupPublicationProfile()
                let (_, wallet) = publicationWallet(route: .channelUsable, profile: profile)
                profile.clearAuthenticatedStateForTesting()
                wallet.replaceEmptyPublicInvoice = true
                PublicPaykitService.setCleanupPending(false)
                var published: [String] = []
                wallet.applyPublicEndpoints = { published = $0.map(\.value) }
                let started = expectation(description: "Initial restoration held")
                let (stream, continuation) = AsyncStream<Void>.makeStream()
                let startup = Task {
                    await profile.initialize {
                        started.fulfill()
                        for await _ in stream {}
                        return restoration
                    }
                }
                await fulfillment(of: [started], timeout: 5)
                await wallet.refreshPaykitEndpointsAfterChannelAvailabilityChanged(reason: "test", forceRefreshLightning: true)
                XCTAssertTrue(published.isEmpty)
                XCTAssertEqual(wallet.publicPaykitBolt11, "ln-public")
                continuation.finish()
                await startup.value
                if profile.automaticPaykitSession == nil {
                    await profile.restoreSessionIfNeeded(hasStoredIdentity: { true }) { .restored(publicKey: owner) }
                }
                let session = try XCTUnwrap(profile.automaticPaykitSession)
                let isCurrent = { profile.automaticPaykitSession == session }
                switch firstPublication {
                case .skipped:
                    do {
                        try await profile.performProfileDeletion {
                            do {
                                try await PublicPaykitService.syncCurrentPublishedEndpoints(
                                    wallet: wallet, isSessionCurrent: isCurrent, syncApp: {}, applyEndpoints: { published = $0.map(\.value) }
                                )
                                XCTFail("Expected deletion to block publication")
                            } catch PubkyServiceError.sessionNotActive {}
                            throw PublicPaykitError.publicationFailed
                        }
                    } catch PublicPaykitError.publicationFailed {}
                case .preparationFailed, .publicationFailed:
                    wallet.failPublicEndpointRefresh = firstPublication == .preparationFailed
                    do {
                        try await PublicPaykitService.syncCurrentPublishedEndpoints(
                            wallet: wallet, isSessionCurrent: isCurrent, syncApp: {},
                            applyEndpoints: { _ in throw PublicPaykitError.publicationFailed }
                        )
                        XCTFail("Expected first publication to fail")
                    } catch {}
                    XCTAssertTrue(PublicPaykitService.isCleanupPending)
                    wallet.failPublicEndpointRefresh = false
                }
                try await PublicPaykitService.syncCurrentPublishedEndpoints(
                    wallet: wallet, isSessionCurrent: isCurrent, syncApp: {}, applyEndpoints: { published = $0.map(\.value) }
                )
                XCTAssertEqual(published, ["ln-current"], "\(restoration), \(firstPublication)")
                XCTAssertFalse(PublicPaykitService.isCleanupPending)
            }
        }
    }

    func testStartupChannelRefreshCannotTransferToAnotherIdentityOrIneligibleCaller() async throws {
        snapshotAppDefaultsDomain()
        enum State: CaseIterable { case replacement, sameKeyNewSession, cancelled, sharingDisabled, noStoredIdentity }
        let owner = "pubky" + String(repeating: "y", count: 52)
        for state in State.allCases {
            AdoptedPubkyReference.current = state == .noStoredIdentity ? nil : ("startup-test", owner)
            let profile = StartupPublicationProfile()
            let (_, wallet) = publicationWallet(route: .channelUsable, profile: profile)
            profile.clearAuthenticatedStateForTesting()
            wallet.replaceEmptyPublicInvoice = true
            wallet.applyPublicEndpoints = { _ in XCTFail("Startup must not publish") }
            if state == .sharingDisabled { UserDefaults.standard.set(false, forKey: PublicPaykitService.publishingEnabledKey) }
            await Task {
                if state == .cancelled { withUnsafeCurrentTask { $0?.cancel() } }
                await wallet.refreshPaykitEndpointsAfterChannelAvailabilityChanged(reason: "test", forceRefreshLightning: true)
            }.value
            if state == .replacement || state == .sameKeyNewSession {
                do {
                    try await profile.signOut(performSessionCleanup: { throw PublicPaykitError.publicationFailed })
                } catch PublicPaykitError.publicationFailed {}
            }
            let restoredOwner = state == .replacement ? "pubky" + String(repeating: "z", count: 52) : owner
            await profile.restoreSessionIfNeeded(hasStoredIdentity: { true }) { .restored(publicKey: restoredOwner) }
            UserDefaults.standard.set(true, forKey: PublicPaykitService.publishingEnabledKey)
            PublicPaykitService.setCleanupPending(false)
            wallet.publicPaykitBolt11 = "ln-current-owner"
            let revision = wallet.publicPaykitInvoiceRevision
            let session = try XCTUnwrap(profile.automaticPaykitSession)
            var published: [String] = []
            try await PublicPaykitService.syncCurrentPublishedEndpoints(
                wallet: wallet, isSessionCurrent: { profile.automaticPaykitSession == session }, syncApp: {},
                applyEndpoints: { published = $0.map(\.value) }
            )
            XCTAssertEqual(published, ["ln-current-owner"], "\(state)")
            XCTAssertEqual(wallet.publicPaykitInvoiceRevision, revision, "\(state)")
            XCTAssertFalse(PublicPaykitService.isCleanupPending, "\(state)")
        }
    }

    func testOlderPublicInvoiceCreationCannotRestoreForcedInvalidation() async throws {
        let (profile, wallet) = publicationWallet(route: .channelUsable)
        wallet.stubPublicEndpoints = false
        let creation = PublicationGate("Public invoice creation")
        wallet.invoiceCreation = {
            wallet.invoiceCreation = nil
            await creation.wait()
            return Self.invoiceWithRouteHints
        }
        let older = Task {
            try await wallet.refreshPublicPaykitEndpoints(includeOnchain: false)
        }
        await fulfillment(of: [creation.started], timeout: 5)
        do {
            try await profile.performProfileDeletion {
                await wallet.refreshPaykitEndpointsAfterChannelAvailabilityChanged(reason: "test", forceRefreshLightning: true)
                creation.release()
                do {
                    _ = try await older.value
                    XCTFail("Expected superseded preparation")
                } catch PubkyServiceError.sessionNotActive {}
                XCTAssertTrue(wallet.publicPaykitBolt11.isEmpty)
                XCTAssertTrue(PublicPaykitService.isCleanupPending)
                throw PublicPaykitError.publicationFailed
            }
        } catch PublicPaykitError.publicationFailed {}
    }

    func testEnablingContactPaymentsRetriesInvoiceSupersessionOnce() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.set(UsdtPreference.disabled.rawValue, forKey: UsdtPreference.key)
        UserDefaults.standard.set(true, forKey: PublicPaykitService.onchainPaymentOptionEnabledKey)
        for duringCreation in [false, true] {
            for invalidations in duringCreation ? [1, 2] : [1] {
                let (profile, wallet) = publicationWallet(route: .channelUsable)
                wallet.stubPublicEndpoints = false
                UserDefaults.standard.set(false, forKey: PublicPaykitService.publishingEnabledKey)
                UserDefaults.standard.set(false, forKey: ContactPaymentsService.confirmedPreferenceKey)
                let session = try XCTUnwrap(profile.currentSession)
                var preparations = 0
                var endpointRefreshes = 0
                wallet.beforePublicEndpointRefresh = { endpointRefreshes += 1 }
                let invalidate = {
                    preparations += 1
                    if !duringCreation || preparations <= invalidations {
                        wallet.publicPaykitBolt11PaymentHash = "paid"
                        wallet.rotatePublicPaykitInvoiceIfNeeded(paymentHash: "paid")
                    }
                }
                wallet.beforeReceiveAddress = { if !duringCreation { invalidate() } }
                wallet.invoiceCreation = {
                    if duringCreation { invalidate() }
                    return Self.invoiceWithRouteHints
                }
                var published: [String] = []
                var removals = 0
                let operations = ContactPaymentsService.Operations(
                    syncPublicEndpoints: { publish, isCurrent in
                        try await PublicPaykitService.syncPublishedEndpoints(
                            wallet: wallet, publish: publish, isSessionCurrent: isCurrent, syncApp: {},
                            applyEndpoints: {
                                if !publish { removals += 1 }
                                published = $0.map(\.value)
                            }
                        )
                    },
                    preparePrivateEndpoints: { _, _, _ in nil }, removePrivateEndpoints: { _ in },
                    setPublicCleanupPending: PublicPaykitService.setCleanupPending,
                    setPrivateCleanupPending: PrivatePaykitService.setContactSharingCleanupPending
                )
                do {
                    let applied = try await ContactPaymentsService.setEnabled(
                        true, pubkyProfile: profile, contactsManager: ContactsManager(),
                        operations: operations, privatePaymentAccess: { _ in false }
                    )
                    XCTAssertEqual(invalidations, 1)
                    XCTAssertTrue(applied)
                    XCTAssertTrue(published.contains(Self.invoiceWithRouteHints))
                    XCTAssertFalse(PublicPaykitService.isCleanupPending, "creation: \(duringCreation)")
                } catch {
                    XCTAssertEqual(invalidations, 2, "\(error), creation: \(duringCreation)")
                    guard case PublicPaykitError.publicationFailed = error else {
                        XCTFail("Expected publication failure, got \(error)")
                        continue
                    }
                    XCTAssertEqual(preparations, 2)
                    XCTAssertTrue(published.isEmpty)
                }
                XCTAssertEqual(profile.currentSession, session)
                XCTAssertEqual(ContactPaymentsService.isEnabled(), invalidations == 1)
                XCTAssertEqual(removals, invalidations == 1 ? 0 : 1)
                XCTAssertEqual(endpointRefreshes, 1)
                XCTAssertEqual(wallet.addressCallCount, 1)
                if !duringCreation { XCTAssertEqual(preparations, 1) }
            }
        }
    }

    func testForcedPublicationUsesOneInvoiceRetryBudget() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.set(UsdtPreference.disabled.rawValue, forKey: UsdtPreference.key)
        UserDefaults.standard.set(true, forKey: PublicPaykitService.onchainPaymentOptionEnabledKey)
        for invalidatesRetry in [false, true] {
            let (profile, wallet) = publicationWallet(route: .channelUsable)
            wallet.stubPublicEndpoints = false
            let session = try XCTUnwrap(profile.automaticPaykitSession)
            var preparations = 0
            var creations = 0
            wallet.beforePublicEndpointRefresh = { preparations += 1 }
            let invalidate = {
                wallet.publicPaykitBolt11PaymentHash = "paid"
                wallet.rotatePublicPaykitInvoiceIfNeeded(paymentHash: "paid")
            }
            wallet.beforeReceiveAddress = { invalidate() }
            wallet.invoiceCreation = {
                creations += 1
                if invalidatesRetry { invalidate() }
                return Self.invoiceWithRouteHints
            }
            var published: [String] = []
            wallet.applyPublicEndpoints = { published = $0.map(\.value) }
            do {
                try await wallet.publishPublicPaykitEndpoints(refreshIfNeeded: true) { profile.automaticPaykitSession == session }
                XCTAssertFalse(invalidatesRetry)
                XCTAssertTrue(published.contains(Self.invoiceWithRouteHints))
                XCTAssertFalse(PublicPaykitService.isCleanupPending)
            } catch PublicPaykitError.publicationFailed {
                XCTAssertTrue(invalidatesRetry)
                XCTAssertTrue(published.isEmpty)
                XCTAssertTrue(wallet.publicPaykitBolt11.isEmpty)
                XCTAssertTrue(PublicPaykitService.isCleanupPending)
            }
            XCTAssertEqual(preparations, 1)
            XCTAssertEqual(wallet.addressCallCount, 1)
            XCTAssertEqual(creations, 1)
            XCTAssertEqual(profile.automaticPaykitSession, session)
        }
    }

    func testCurrentPublicationAcknowledgesRetriedInvoiceSnapshot() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.set(UsdtPreference.disabled.rawValue, forKey: UsdtPreference.key)
        UserDefaults.standard.set(true, forKey: PublicPaykitService.onchainPaymentOptionEnabledKey)
        let (profile, wallet) = publicationWallet(route: .channelUsable)
        wallet.stubPublicEndpoints = false
        wallet.invoiceCreation = { Self.invoiceWithRouteHints }
        wallet.beforeReceiveAddress = {
            wallet.beforeReceiveAddress = nil
            wallet.publicPaykitBolt11PaymentHash = "paid"
            wallet.rotatePublicPaykitInvoiceIfNeeded(paymentHash: "paid")
        }
        let session = try XCTUnwrap(profile.automaticPaykitSession)
        var published: [String] = []
        try await PublicPaykitService.syncCurrentPublishedEndpoints(
            wallet: wallet, isSessionCurrent: { profile.automaticPaykitSession == session }, syncApp: {},
            applyEndpoints: { published = $0.map(\.value) }
        )
        XCTAssertTrue(published.contains(Self.invoiceWithRouteHints))
        XCTAssertFalse(PublicPaykitService.isCleanupPending)
    }

    func testInvoiceSupersessionDoesNotRetryCreationOrDecodeFailures() async throws {
        for failsCreation in [false, true] {
            let (_, wallet) = publicationWallet(route: .channelUsable)
            wallet.stubPublicEndpoints = false
            var creations = 0
            wallet.invoiceCreation = {
                creations += 1
                wallet.publicPaykitBolt11PaymentHash = "paid"
                wallet.rotatePublicPaykitInvoiceIfNeeded(paymentHash: "paid")
                if failsCreation { throw PublicPaykitError.walletNotReady }
                return "invalid-invoice"
            }
            do {
                _ = try await wallet.refreshPublicPaykitEndpoints(includeOnchain: false)
                XCTFail("Expected invoice failure")
            } catch {
                if failsCreation {
                    guard case PublicPaykitError.walletNotReady = error else { return XCTFail("Unexpected error: \(error)") }
                } else {
                    XCTAssertFalse(error is PubkyServiceError)
                    XCTAssertFalse(error is PublicPaykitError)
                }
            }
            XCTAssertEqual(creations, 1)
            XCTAssertTrue(wallet.publicPaykitBolt11.isEmpty)
        }
    }

    func testEnablingContactPaymentsRejectsDeletionBeforeOrDuringInvoiceRetry() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.set(UsdtPreference.disabled.rawValue, forKey: UsdtPreference.key)
        for heldCreation in [1, 2] {
            let (profile, wallet) = publicationWallet(route: .channelUsable)
            wallet.stubPublicEndpoints = false
            UserDefaults.standard.set(false, forKey: PublicPaykitService.publishingEnabledKey)
            UserDefaults.standard.set(false, forKey: ContactPaymentsService.confirmedPreferenceKey)
            let session = try XCTUnwrap(profile.currentSession)
            let creation = PublicationGate("Public invoice creation before deletion")
            var creations = 0
            wallet.invoiceCreation = {
                creations += 1
                if creations == 1 {
                    wallet.publicPaykitBolt11PaymentHash = "paid"
                    wallet.rotatePublicPaykitInvoiceIfNeeded(paymentHash: "paid")
                }
                if creations == heldCreation { await creation.wait() }
                return Self.invoiceWithRouteHints
            }
            let operations = ContactPaymentsService.Operations(
                syncPublicEndpoints: { publish, isCurrent in
                    try await PublicPaykitService.syncPublishedEndpoints(
                        wallet: wallet, publish: publish, isSessionCurrent: isCurrent, syncApp: {},
                        applyEndpoints: { XCTAssertTrue($0.isEmpty, "Deletion must not publish replacement endpoints") }
                    )
                },
                preparePrivateEndpoints: { _, _, _ in nil }, removePrivateEndpoints: { _ in },
                setPublicCleanupPending: PublicPaykitService.setCleanupPending,
                setPrivateCleanupPending: PrivatePaykitService.setContactSharingCleanupPending
            )
            let change = Task {
                try await ContactPaymentsService.setEnabled(
                    true, pubkyProfile: profile, contactsManager: ContactsManager(),
                    operations: operations, privatePaymentAccess: { _ in false }
                )
            }
            await fulfillment(of: [creation.started], timeout: 5)
            await profile.performProfileDeletion {
                XCTAssertEqual(profile.currentSession, session)
                creation.release()
                do {
                    _ = try await change.value
                    XCTFail("Expected deletion to reject invoice retry")
                } catch PubkyServiceError.sessionNotActive {
                } catch {
                    XCTFail("Unexpected error: \(error)")
                }
                XCTAssertTrue(wallet.publicPaykitBolt11.isEmpty)
                XCTAssertFalse(ContactPaymentsService.isEnabled())
                XCTAssertEqual(creations, heldCreation)
            }
        }
    }

    func testAdmittedPublicWriteCannotAcknowledgeNewerChannelRefresh() async throws {
        snapshotAppDefaults(PublicPaykitService.onchainPaymentOptionEnabledKey)
        UserDefaults.standard.set(true, forKey: PublicPaykitService.onchainPaymentOptionEnabledKey)
        for refreshIfNeeded in [false, true] {
            for invoice in ["ln-public", ""] {
                let (profile, wallet) = publicationWallet(route: .channelUsable)
                wallet.publicPaykitBolt11 = invoice
                wallet.publicEndpointAddress = "bcrt1qreceive"
                PublicPaykitService.setCleanupPending(false)
                let session = try XCTUnwrap(profile.automaticPaykitSession)
                let write = PublicationGate("Admitted public write")
                wallet.applyPublicEndpoints = { _ in await write.wait() }
                let publication = Task {
                    try await wallet.publishPublicPaykitEndpoints(
                        refreshIfNeeded: refreshIfNeeded, isSessionCurrent: { profile.automaticPaykitSession == session }
                    )
                }
                await fulfillment(of: [write.started], timeout: 5)
                do {
                    try await profile.performProfileDeletion {
                        await wallet.refreshPaykitEndpointsAfterChannelAvailabilityChanged(reason: "test", forceRefreshLightning: true)
                        throw PublicPaykitError.publicationFailed
                    }
                } catch PublicPaykitError.publicationFailed {}
                write.release()
                try await publication.value
                XCTAssertTrue(PublicPaykitService.isCleanupPending, "Invoice: \(invoice), refresh: \(refreshIfNeeded)")
            }
        }
    }

    func testForcedChannelRefreshDoesNotInvalidateWithoutEligibleIdentityAndSharing() async throws {
        enum State: CaseIterable { case signedOut, restoring, sharingDisabled, lightningDisabled, cancelled }
        for state in State.allCases {
            let (profile, wallet) = publicationWallet(route: .channelUsable)
            PublicPaykitService.setCleanupPending(false)
            switch state {
            case .signedOut: profile.clearAuthenticatedStateForTesting()
            case .restoring: profile.authState = .idle
            case .sharingDisabled: UserDefaults.standard.set(false, forKey: PublicPaykitService.publishingEnabledKey)
            case .lightningDisabled: UserDefaults.standard.set(false, forKey: PublicPaykitService.lightningPaymentOptionEnabledKey)
            case .cancelled: break
            }
            do {
                try await profile.performProfileDeletion {
                    await Task {
                        if state == .cancelled { withUnsafeCurrentTask { $0?.cancel() } }
                        await wallet.refreshPaykitEndpointsAfterChannelAvailabilityChanged(reason: "test", forceRefreshLightning: true)
                    }.value
                    throw PublicPaykitError.publicationFailed
                }
            } catch PublicPaykitError.publicationFailed {}
            XCTAssertEqual(wallet.publicPaykitBolt11, "ln-public", "\(state)")
            XCTAssertFalse(PublicPaykitService.isCleanupPending, "\(state)")
        }
    }

    func testSuspendedPublicInvoiceCreationCannotMutateChangedOwnerOrSharing() async throws {
        enum State: CaseIterable { case replaced, sameKeyNewSession, sharingDisabled, uiDisabled, cancelled }
        for state in State.allCases {
            let (profile, wallet) = publicationWallet(route: .channelUsable)
            wallet.stubPublicEndpoints = false
            let creation = PublicationGate("Public invoice creation")
            wallet.invoiceCreation = {
                await creation.wait()
                return Self.invoiceWithRouteHints
            }
            let preparation = Task { try await wallet.refreshPublicPaykitEndpoints(includeOnchain: false) }
            await fulfillment(of: [creation.started], timeout: 5)
            wallet.publicPaykitBolt11PaymentHash = "paid"
            wallet.rotatePublicPaykitInvoiceIfNeeded(paymentHash: "paid")
            switch state {
            case .replaced: profile.publicKey = "pubky" + String(repeating: "z", count: 52)
            case .sameKeyNewSession:
                do {
                    try await profile.signOut(performSessionCleanup: { throw PublicPaykitError.publicationFailed })
                } catch PublicPaykitError.publicationFailed {}
            case .sharingDisabled: UserDefaults.standard.set(false, forKey: PublicPaykitService.publishingEnabledKey)
            case .uiDisabled: UserDefaults.standard.set(false, forKey: PaykitFeatureFlags.uiEnabledKey)
            case .cancelled: preparation.cancel()
            }
            wallet.publicPaykitBolt11 = "ln-retained"
            creation.release()
            do {
                _ = try await preparation.value
                XCTFail("Expected superseded preparation")
            } catch PubkyServiceError.sessionNotActive {}
            XCTAssertEqual(wallet.publicPaykitBolt11, "ln-retained", "\(state)")
        }
    }

    func testLatePublicSnapshotRestoresPendingAfterReplacementWasAcknowledged() async throws {
        for forceRefresh in [false, true] {
            let (profile, wallet) = publicationWallet(route: .channelUsable)
            let session = try XCTUnwrap(profile.automaticPaykitSession)
            let preparation = PublicationGate("Older endpoint snapshot")
            wallet.afterPublicEndpointSnapshot = {
                wallet.afterPublicEndpointSnapshot = nil
                await preparation.wait()
            }
            var published: [String] = []
            wallet.applyPublicEndpoints = { published += $0.map(\.value) }
            let older = Task {
                try await wallet.publishPublicPaykitEndpoints(refreshIfNeeded: forceRefresh) { profile.automaticPaykitSession == session }
            }
            await fulfillment(of: [preparation.started], timeout: 5)
            wallet.publicPaykitBolt11PaymentHash = "paid"
            wallet.rotatePublicPaykitInvoiceIfNeeded(paymentHash: "paid")
            wallet.publicPaykitBolt11 = "ln-replacement"
            try await PublicPaykitService.syncCurrentPublishedEndpoints(
                wallet: wallet, isSessionCurrent: { profile.automaticPaykitSession == session }, syncApp: {},
                applyEndpoints: { published += $0.map(\.value) }
            )
            XCTAssertFalse(PublicPaykitService.isCleanupPending)
            preparation.release()
            try await older.value
            XCTAssertEqual(published, ["ln-replacement", "ln-public"])
            XCTAssertTrue(PublicPaykitService.isCleanupPending, "Forced: \(forceRefresh)")
            try await PublicPaykitService.syncCurrentPublishedEndpoints(
                wallet: wallet, isSessionCurrent: { profile.automaticPaykitSession == session }, syncApp: {},
                applyEndpoints: { published += $0.map(\.value) }
            )
            XCTAssertEqual(published.last, "ln-replacement")
            XCTAssertFalse(PublicPaykitService.isCleanupPending)
        }
    }

    func testSharingChangesPreservePublicPublicationAcknowledgement() async throws {
        snapshotAppDefaultsDomain()
        UserDefaults.standard.set(UsdtPreference.disabled.rawValue, forKey: UsdtPreference.key)
        for restoresSharing in [false, true] {
            for replacesInvoice in [false, true] {
                let (profile, wallet) = publicationWallet(route: .channelUsable)
                let session = try XCTUnwrap(profile.automaticPaykitSession)
                UserDefaults.standard.set(restoresSharing, forKey: PublicPaykitService.publishingEnabledKey)
                PublicPaykitService.setCleanupPending(!replacesInvoice)
                let contacts = ContactsManager()
                let preparation = PublicationGate("Explicit endpoint snapshot")
                wallet.afterPublicEndpointSnapshot = {
                    wallet.afterPublicEndpointSnapshot = nil
                    await preparation.wait()
                }
                var publications = 0
                var published: [String] = []
                let operations = ContactPaymentsService.Operations(
                    syncPublicEndpoints: { publish, isChangeCurrent in
                        publications += 1
                        if restoresSharing, publications == 1 { throw PublicPaykitError.publicationFailed }
                        XCTAssertTrue(publish)
                        XCTAssertTrue(isChangeCurrent())
                        XCTAssertTrue(UserDefaults.standard.bool(forKey: PublicPaykitService.publishingEnabledKey))
                        try await PublicPaykitService.syncPublishedEndpoints(
                            wallet: wallet, publish: publish, isSessionCurrent: isChangeCurrent, syncApp: {},
                            applyEndpoints: { published += $0.map(\.value) }
                        )
                    },
                    preparePrivateEndpoints: { _, _, _ in nil },
                    removePrivateEndpoints: { _ in },
                    setPublicCleanupPending: PublicPaykitService.setCleanupPending,
                    setPrivateCleanupPending: PrivatePaykitService.setContactSharingCleanupPending
                )
                let change = Task {
                    try await ContactPaymentsService.setEnabled(
                        true, pubkyProfile: profile, contactsManager: contacts,
                        operations: operations, privatePaymentAccess: { _ in false }
                    )
                }
                await fulfillment(of: [preparation.started], timeout: 5)
                if replacesInvoice {
                    wallet.publicPaykitBolt11PaymentHash = "paid"
                    wallet.rotatePublicPaykitInvoiceIfNeeded(paymentHash: "paid")
                    wallet.publicPaykitBolt11 = "ln-replacement"
                    try await PublicPaykitService.syncCurrentPublishedEndpoints(
                        wallet: wallet, isSessionCurrent: { profile.automaticPaykitSession == session }, syncApp: {},
                        applyEndpoints: { published += $0.map(\.value) }
                    )
                    XCTAssertFalse(PublicPaykitService.isCleanupPending)
                }
                preparation.release()
                do {
                    let applied = try await change.value
                    XCTAssertFalse(restoresSharing)
                    XCTAssertTrue(applied)
                } catch PublicPaykitError.publicationFailed {
                    XCTAssertTrue(restoresSharing)
                }
                XCTAssertEqual(published, replacesInvoice ? ["ln-replacement", "ln-public"] : ["ln-public"])
                XCTAssertEqual(PublicPaykitService.isCleanupPending, replacesInvoice, "Restore: \(restoresSharing)")
                await ContactPaymentsService.reconcilePendingEndpoints {
                    guard PublicPaykitService.isCleanupPending else { return }
                    try? await PublicPaykitService.syncCurrentPublishedEndpoints(
                        wallet: wallet, isSessionCurrent: { profile.automaticPaykitSession == session }, syncApp: {},
                        applyEndpoints: { published += $0.map(\.value) }
                    )
                }
                XCTAssertEqual(published.last, replacesInvoice ? "ln-replacement" : "ln-public")
                XCTAssertFalse(PublicPaykitService.isCleanupPending)
            }
        }
    }

    private static let invoiceWithRouteHints =
        "lnbcrt200n1p5hn4c8dqqnp4qwrgh4a03djj2sl34465uwnxhva0gtpjm4u8kvzgc5jergrkm9syypp55lwcgfpkdwuknmekjgted72n0ddl5qtaha7knk7c9n7yrjr4auassp5jgqw0a9w33e2ta4j7gyjrvsvu0lv844w895305nd8spnknq3f2hq9qyysgqcqzp2xqyz5vqrzjq29gjy9sqjrrp48tz7hj2e5vm4l2dukc4csf2mn6qm32u3hted5leapyqqqqqqqtcsqqqqlgqqqqqqgq2qd2gk64eg2kfxtdaryrlh98hvu97jdaxz2ma7aeyuy2uy9vkn9x5qft47p9taju297xnrehva20xcfml7wacuv737xv3xjjzyrtplcxqpfpu9dt"

    func testAutomaticPublicationRetainsStartingSessionAcrossPreparation() async throws {
        enum EndState: CaseIterable { case signedOut, replaced, sessionChanged, restoring, sharingDisabled, cancelled }
        for route in AutomaticPublicationRoute.allCases {
            for endState in EndState.allCases {
                let (profile, wallet) = publicationWallet(route: route)
                let preparation = PublicationGate("Local receive preparation")
                wallet.beforeReceiveAddress = { await preparation.wait() }
                var writes = 0
                wallet.applyPublicEndpoints = { _ in writes += 1 }
                let publication = Task { try await route.refresh(wallet) }
                await fulfillment(of: [preparation.started], timeout: 5)
                switch endState {
                case .signedOut: profile.clearAuthenticatedStateForTesting()
                case .replaced: profile.publicKey = "pubky" + String(repeating: "z", count: 52)
                case .sessionChanged:
                    let session = profile.automaticPaykitSession
                    do {
                        try await profile.signOut { throw PublicPaykitError.publicationFailed }
                        XCTFail("Expected cleanup failure")
                    } catch PublicPaykitError.publicationFailed {}
                    XCTAssertNotEqual(profile.automaticPaykitSession, session)
                    XCTAssertEqual(profile.automaticPaykitSession?.publicKey, session?.publicKey)
                case .restoring: profile.authState = .idle
                case .sharingDisabled: UserDefaults.standard.set(false, forKey: PublicPaykitService.publishingEnabledKey)
                case .cancelled: publication.cancel()
                }
                preparation.release()
                do { try await publication.value } catch is CancellationError {}
                XCTAssertEqual(writes, 0, "\(route), \(endState)")
            }
        }
    }

    func testDeletionRemovesAdmittedAutomaticWriteEvenWhenCallerIsCancelled() async throws {
        for route in AutomaticPublicationRoute.allCases {
            let (profile, wallet) = publicationWallet(route: route)
            let write = PublicationGate("Admitted endpoint write")
            let cleanup = expectation(description: "Cleanup attempting endpoint removal")
            var events: [String] = []
            var endpoints: [String] = []
            wallet.applyPublicEndpoints = {
                await write.wait()
                endpoints = $0.map(\.value)
                events.append("published")
            }
            let publication = Task { try await route.refresh(wallet) }
            await fulfillment(of: [write.started], timeout: 5)
            let deletion = Task {
                try await profile.performProfileDeletion {
                    cleanup.fulfill()
                    try await PublicPaykitService.syncPublishedEndpoints(
                        publish: false, buildEndpoints: { [] }, syncApp: {},
                        applyEndpoints: {
                            endpoints = $0.map(\.value)
                            events.append("removed")
                        }
                    )
                }
            }
            await fulfillment(of: [cleanup], timeout: 5)
            XCTAssertTrue(events.isEmpty)
            publication.cancel()
            write.release()
            try await publication.value
            try await deletion.value
            XCTAssertEqual(events, ["published", "removed"], "\(route)")
            XCTAssertTrue(endpoints.isEmpty)
            XCTAssertEqual(wallet.publicationRefreshModes, [route == .channelUsable])
        }
    }

    private func publicationWallet(
        route: AutomaticPublicationRoute, profile: PubkyProfileManager? = nil
    ) -> (PubkyProfileManager, GatedReceiveWallet) {
        UserDefaults.standard.set(true, forKey: PublicPaykitService.publishingEnabledKey)
        UserDefaults.standard.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
        UserDefaults.standard.set(true, forKey: PublicPaykitService.lightningPaymentOptionEnabledKey)
        UserDefaults.standard.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
        let profile = profile ?? PubkyProfileManager()
        profile.publicKey = "pubky" + String(repeating: "y", count: 52)
        profile.authState = .authenticated
        let wallet = GatedReceiveWallet(pubkyProfile: profile)
        wallet.stubPublicEndpoints = true
        wallet.publicPaykitBolt11 = "ln-public"
        wallet.usableChannels = route == .channelUsable
        return (profile, wallet)
    }

    private enum AutomaticPublicationRoute: CaseIterable {
        case receive, channelUsable, channelUnavailable

        func refresh(_ wallet: GatedReceiveWallet) async throws {
            switch self {
            case .receive: try await wallet.refreshBip21(forceRefreshBolt11: true)
            case .channelUsable, .channelUnavailable:
                await wallet.refreshPaykitEndpointsAfterChannelAvailabilityChanged(reason: "test")
            }
        }
    }

    func testDeletionDefersPublicationAfterInvoiceCreationWithoutDiscardingInvoice() async throws {
        UserDefaults.standard.set(true, forKey: PublicPaykitService.publishingEnabledKey)
        UserDefaults.standard.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
        let wallet = GatedReceiveWallet()
        wallet.invoiceAmountSats = 1000
        let refresh = Task { try await wallet.refreshBip21(forceRefreshBolt11: true) }
        await fulfillment(of: [wallet.olderStarted], timeout: 5)
        await PrivatePaykitService.shared.beginProfileDeletion()
        wallet.releaseOlderInvoice()
        do {
            try await refresh.value
            XCTAssertTrue(wallet.hasCoherentReceiveInvoice)
            XCTAssertEqual(wallet.endpointSyncCount, 0)
        } catch {
            await PrivatePaykitService.shared.endProfileDeletion()
            throw error
        }
        await PrivatePaykitService.shared.endProfileDeletion()
        wallet.failPublicEndpointRefresh = true
        for _ in 0 ..< 2 {
            await wallet.refreshPublicPaykitEndpointsOnForeground { true }
            XCTAssertTrue(PublicPaykitService.isCleanupPending)
            XCTAssertEqual(PublicPaykitService.pendingReconciliationMode(), .publishEndpoints)
        }
        wallet.invoiceAmountSats = 2000
        try await wallet.refreshBip21(forceRefreshBolt11: true)
        XCTAssertEqual(wallet.endpointSyncCount, 1)
    }

    func testFailedPublicRefreshDoesNotMarkReconciliationAfterSessionOrSharingEnds() async throws {
        enum EndState: CaseIterable {
            case signedOut, identityChanged, sharingDisabled, cancelled
        }
        UserDefaults.standard.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
        for endState in EndState.allCases {
            UserDefaults.standard.set(true, forKey: PublicPaykitService.publishingEnabledKey)
            PublicPaykitService.setCleanupPending(false)
            let profile = PubkyProfileManager()
            profile.publicKey = "pubky" + String(repeating: "y", count: 52)
            profile.authState = .authenticated
            let session = try XCTUnwrap(profile.currentSession)
            let wallet = GatedReceiveWallet()
            wallet.failPublicEndpointRefresh = true
            wallet.beforePublicEndpointRefresh = {
                switch endState {
                case .signedOut:
                    profile.clearAuthenticatedStateForTesting()
                case .identityChanged:
                    profile.publicKey = "pubky" + String(repeating: "z", count: 52)
                case .sharingDisabled:
                    UserDefaults.standard.set(false, forKey: PublicPaykitService.publishingEnabledKey)
                case .cancelled:
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                PublicPaykitService.setCleanupPending(false)
            }
            await Task {
                await wallet.refreshPublicPaykitEndpointsOnForeground { profile.automaticPaykitSession == session }
            }.value
            XCTAssertFalse(PublicPaykitService.isCleanupPending)
        }
    }

    func testPaidPublicInvoiceRemainsPendingWhileDeletionDefersPublication() async {
        UserDefaults.standard.set(true, forKey: PublicPaykitService.publishingEnabledKey)
        let wallet = GatedReceiveWallet()
        wallet.publicPaykitBolt11 = "ln-paid"
        wallet.publicPaykitBolt11PaymentHash = "paid-hash"
        await PrivatePaykitService.shared.beginProfileDeletion()
        wallet.rotatePublicPaykitInvoiceIfNeeded(paymentHash: "unrelated")
        XCTAssertEqual(wallet.publicPaykitBolt11, "ln-paid")
        XCTAssertFalse(PublicPaykitService.isCleanupPending)
        wallet.rotatePublicPaykitInvoiceIfNeeded(paymentHash: "paid-hash")
        XCTAssertTrue(wallet.publicPaykitBolt11.isEmpty)
        XCTAssertTrue(PublicPaykitService.isCleanupPending)
        await PrivatePaykitService.shared.endProfileDeletion()
    }

    func testAdmittedPublicWriteCannotAcknowledgeNewerPaidInvoiceInvalidation() async throws {
        UserDefaults.standard.set(true, forKey: PublicPaykitService.publishingEnabledKey)
        UserDefaults.standard.set(true, forKey: PublicPaykitService.lightningPaymentOptionEnabledKey)
        let wallet = GatedReceiveWallet()
        wallet.stubPublicEndpoints = true
        wallet.publicPaykitBolt11 = "ln-paid"
        wallet.publicPaykitBolt11PaymentHash = "paid-hash"
        PublicPaykitService.setCleanupPending(true)
        let admitted = expectation(description: "Public write admitted")
        var finishWrite: CheckedContinuation<Void, Never>?
        var writtenInvoices: [String] = []
        let publication = Task {
            try await PublicPaykitService.syncCurrentPublishedEndpoints(
                wallet: wallet,
                isSessionCurrent: { true },
                syncApp: {},
                applyEndpoints: { endpoints in
                    await withCheckedContinuation {
                        finishWrite = $0
                        admitted.fulfill()
                    }
                    writtenInvoices.append(endpoints.first { $0.methodId == .bitcoinLightningBolt11 }?.value ?? "")
                }
            )
        }
        await fulfillment(of: [admitted], timeout: 2)
        wallet.rotatePublicPaykitInvoiceIfNeeded(paymentHash: "paid-hash")
        finishWrite?.resume()
        try await publication.value
        XCTAssertEqual(writtenInvoices, ["ln-paid"])
        XCTAssertTrue(PublicPaykitService.isCleanupPending)

        wallet.publicPaykitBolt11 = "ln-replacement"
        do {
            try await PublicPaykitService.syncCurrentPublishedEndpoints(
                wallet: wallet, isSessionCurrent: { true }, syncApp: {},
                applyEndpoints: { _ in throw PublicPaykitError.publicationFailed }
            )
            XCTFail("Expected publication failure")
        } catch PublicPaykitError.publicationFailed {}
        XCTAssertTrue(PublicPaykitService.isCleanupPending)
        try await PublicPaykitService.syncCurrentPublishedEndpoints(
            wallet: wallet, isSessionCurrent: { true }, syncApp: {},
            applyEndpoints: { endpoints in
                writtenInvoices.append(endpoints.first { $0.methodId == .bitcoinLightningBolt11 }?.value ?? "")
            }
        )
        XCTAssertEqual(writtenInvoices, ["ln-paid", "ln-replacement"])
        XCTAssertFalse(PublicPaykitService.isCleanupPending)
    }

    func testPublicWriteDoesNotAcknowledgePendingWorkWithoutCurrentSession() async throws {
        UserDefaults.standard.set(true, forKey: PublicPaykitService.publishingEnabledKey)
        let wallet = GatedReceiveWallet()
        wallet.stubPublicEndpoints = true
        for hasSessionFence in [false, true] {
            PublicPaykitService.setCleanupPending(true)
            var currentSession = true
            let fence: @MainActor () -> Bool = { currentSession }
            try await PublicPaykitService.syncCurrentPublishedEndpoints(
                wallet: wallet, isSessionCurrent: hasSessionFence ? fence : nil, syncApp: {},
                applyEndpoints: { _ in currentSession = false }
            )
            XCTAssertTrue(PublicPaykitService.isCleanupPending)
        }
    }

    func testRefreshUsesCapturedInputsAndPreservesEditsMadeWhileWaiting() async throws {
        let wallet = GatedReceiveWallet()
        wallet.invoiceAmountSats = 1000
        wallet.invoiceNote = "older"
        let refresh = Task { try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false) }
        await fulfillment(of: [wallet.olderStarted], timeout: 5)
        XCTAssertTrue(wallet.isReceiveInvoiceUpdating)
        wallet.invoiceAmountSats = 2000
        wallet.invoiceNote = "newer"
        wallet.releaseOlderInvoice()
        try await refresh.value
        XCTAssertTrue(wallet.bip21.contains("amount=0.00001"))
        XCTAssertTrue(wallet.bip21.contains("message=older"))
        XCTAssertEqual(wallet.invoiceAmountSats, 2000)
        XCTAssertEqual(wallet.invoiceNote, "newer")
    }

    func testFailureEndsPendingAndRetryUsesCurrentEdits() async throws {
        let wallet = GatedReceiveWallet()
        wallet.invoiceAmountSats = 2000
        wallet.failNextInvoice = true
        do {
            try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false)
            XCTFail("Expected invoice failure")
        } catch {}
        XCTAssertNotNil(wallet.receiveInvoiceError)
        XCTAssertFalse(wallet.isReceiveInvoiceUpdating)
        wallet.invoiceNote = "retry & note"
        try await wallet.refreshBip21(syncPublicPaykit: false)
        XCTAssertNil(wallet.receiveInvoiceError)
        XCTAssertTrue(wallet.hasCoherentReceiveInvoice)
        XCTAssertEqual(URLComponents(string: wallet.bip21)?.queryItems?.first(where: { $0.name == "message" })?.value, "retry & note")
    }

    func testCancelledNewestRequestDoesNotStrandPendingOrRepublishStaleInvoice() async throws {
        let wallet = GatedReceiveWallet()
        wallet.invoiceAmountSats = 1000
        let refresh = Task { try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false) }
        await fulfillment(of: [wallet.olderStarted], timeout: 5)
        refresh.cancel()
        wallet.releaseOlderInvoice()
        do { try await refresh.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(wallet.isReceiveInvoiceUpdating)
        XCTAssertTrue(wallet.bolt11.isEmpty)
        XCTAssertNotNil(wallet.receiveInvoiceError)
        wallet.invoiceAmountSats = 2000
        try await wallet.refreshBip21(syncPublicPaykit: false)
        XCTAssertTrue(wallet.hasCoherentReceiveInvoice)
    }

    func testCancelledOlderRequestDoesNotClearNewerResult() async throws {
        let wallet = GatedReceiveWallet()
        wallet.invoiceAmountSats = 1000
        let older = Task { try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false) }
        await fulfillment(of: [wallet.olderStarted], timeout: 5)
        wallet.invoiceAmountSats = 2000
        try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false)
        older.cancel()
        wallet.releaseOlderInvoice()
        do { try await older.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(wallet.bolt11, "ln-newer")
        XCTAssertNil(wallet.receiveInvoiceError)
        XCTAssertFalse(wallet.isReceiveInvoiceUpdating)
    }

    func testOlderAddressRefreshCannotOverwriteNewerAddressOrInvoice() async throws {
        let wallet = GatedReceiveWallet()
        wallet.gateFirstAddress = true
        wallet.invoiceAmountSats = 2000
        let older = Task { try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false) }
        await fulfillment(of: [wallet.olderAddressStarted], timeout: 5)
        try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false)
        wallet.releaseOlderAddress()
        try await older.value
        XCTAssertEqual(wallet.onchainAddress, "bcrt1qreceive")
        XCTAssertTrue(wallet.bip21.hasPrefix("bitcoin:bcrt1qreceive"))
        XCTAssertTrue(wallet.hasCoherentReceiveInvoice)
    }

    func testEndpointRefreshCannotReplaceReceiveAddressCommittedDuringItsAwait() async throws {
        try await assertEndpointRefreshPreservesReceiveAddress(initialAddress: "")
    }

    func testEndpointRefreshCannotReplaceNewInvoiceWhenReceiveKeepsTheSameAddress() async throws {
        try await assertEndpointRefreshPreservesReceiveAddress(initialAddress: "bcrt1qreceive")
    }

    private func assertEndpointRefreshPreservesReceiveAddress(initialAddress: String) async throws {
        UserDefaults.standard.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
        let wallet = GatedReceiveWallet()
        wallet.onchainAddress = initialAddress
        wallet.invoiceAmountSats = 1000
        let receive = Task { try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false) }
        await fulfillment(of: [wallet.olderStarted], timeout: 5)
        wallet.gateSecondAddress = true
        let endpoint = Task { try await wallet.refreshPublicPaykitEndpoints(includeLightning: false) }
        await fulfillment(of: [wallet.endpointAddressStarted], timeout: 5)
        wallet.releaseOlderInvoice()
        try await receive.value
        wallet.releaseEndpointAddress()
        _ = try await endpoint.value
        XCTAssertEqual(wallet.onchainAddress, "bcrt1qreceive")
        XCTAssertTrue(wallet.bip21.hasPrefix("bitcoin:bcrt1qreceive"))
        XCTAssertTrue(wallet.hasCoherentReceiveInvoice)
    }

    func testNewerRefreshPreservesTagsWhileOlderInvoiceHashIsResolving() async throws {
        let wallet = taggedReceiveWallet()
        let older = Task { try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false) }
        await fulfillment(of: [wallet.firstHashStarted], timeout: 5)
        try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false)
        wallet.releaseFirstHash()
        try await older.value
        XCTAssertEqual(wallet.bolt11, "ln-second")
        XCTAssertEqual(wallet.metadata["ln-second"], ["Lunch"])
        XCTAssertTrue(wallet.hasCoherentReceiveInvoice)
    }

    func testNewerRefreshPreservesTagsWhileOlderMetadataSaveIsPending() async throws {
        let wallet = taggedReceiveWallet()
        wallet.gateFirstHash = false
        wallet.gateFirstWrite = true
        let older = Task { try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false) }
        await fulfillment(of: [wallet.firstWriteStarted], timeout: 5)
        XCTAssertEqual(wallet.bolt11, "ln-initial")
        try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false)
        wallet.releaseFirstWrite()
        try await older.value
        XCTAssertEqual(wallet.bolt11, "ln-second")
        XCTAssertEqual(wallet.metadata["ln-second"], ["Lunch"])
    }

    func testCancellationDuringMetadataSaveDoesNotPublishInvoiceAndRetryKeepsTags() async throws {
        let wallet = taggedReceiveWallet()
        wallet.gateFirstHash = false
        wallet.gateFirstWrite = true
        let refresh = Task { try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false) }
        await fulfillment(of: [wallet.firstWriteStarted], timeout: 5)
        refresh.cancel()
        wallet.releaseFirstWrite()
        do {
            try await refresh.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(wallet.bolt11, "ln-initial")
        XCTAssertFalse(wallet.isReceiveInvoiceUpdating)
        try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false)
        XCTAssertEqual(wallet.metadata["ln-second"], ["Lunch"])
        XCTAssertTrue(wallet.hasCoherentReceiveInvoice)
    }

    func testDeletedTagAfterCancelledReplacementDoesNotReturnOnRetry() async throws {
        let wallet = taggedReceiveWallet()
        wallet.gateFirstHash = false
        wallet.gateFirstWrite = true
        let refresh = Task { try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false) }
        await fulfillment(of: [wallet.firstWriteStarted], timeout: 5)
        refresh.cancel()
        wallet.releaseFirstWrite()
        do { try await refresh.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        try await wallet.mutateReceiveTags(.remove(["Lunch"]))
        try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false)
        XCTAssertEqual(wallet.metadata["ln-second"], [])
    }

    func testTagAdditionAfterCancelledReplacementSurvivesRetry() async throws {
        try await assertTagMutationAfterCancelledReplacement(.add(["Dinner"]), expected: ["Dinner", "Lunch"])
    }

    func testTagResetAfterCancelledReplacementSurvivesRetry() async throws {
        try await assertTagMutationAfterCancelledReplacement(.reset, expected: [])
    }

    private func assertTagMutationAfterCancelledReplacement(_ mutation: Bitkit.ReceiveTagMutation, expected: [String]) async throws {
        let wallet = taggedReceiveWallet()
        wallet.gateFirstHash = false
        wallet.gateFirstWrite = true
        let refresh = Task { try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false) }
        await fulfillment(of: [wallet.firstWriteStarted], timeout: 5)
        refresh.cancel()
        wallet.releaseFirstWrite()
        do { try await refresh.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        try await wallet.mutateReceiveTags(mutation)
        try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false)
        XCTAssertEqual(wallet.metadata["ln-second"], expected)
    }

    func testExistingEmptyTagsDoNotUseAddressFallback() async throws {
        let wallet = taggedReceiveWallet()
        wallet.gateFirstHash = false
        wallet.metadata["ln-initial"] = []
        try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false)
        XCTAssertEqual(wallet.metadata["ln-first"], [])
        XCTAssertEqual(wallet.addressReads, 0)
    }

    func testMissingInvoiceTagsUseCommittedInvoiceAddressNotProvisionalAddress() async throws {
        let wallet = taggedReceiveWallet()
        wallet.gateFirstHash = false
        wallet.metadata = ["replacement": ["Lunch"], "unrelated": ["Wrong"]]
        wallet.metadataAddresses = ["replacement": "bcrt1qreceive", "unrelated": "bcrt1qprovisional"]
        wallet.onchainAddress = "bcrt1qprovisional"
        try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false)
        XCTAssertEqual(wallet.metadata["ln-first"], ["Lunch"])
        XCTAssertEqual(wallet.addressReads, 1)
    }

    private func taggedReceiveWallet() -> TaggedReceiveWallet {
        let wallet = TaggedReceiveWallet()
        wallet.onchainAddress = "bcrt1qreceive"
        wallet.bolt11 = "ln-initial"
        wallet.bip21 = "bitcoin:bcrt1qreceive?lightning=ln-initial"
        return wallet
    }

    func testPaymentReceivedDuringRevalidationDoesNotRecommitPaidInvoice() async throws {
        let wallet = GatedReceiveWallet()
        seedReusableInvoice(wallet)
        wallet.reusableInvoice = true
        wallet.gateFirstAddress = true
        let refresh = Task { try await wallet.refreshBip21(syncPublicPaykit: false) }
        await fulfillment(of: [wallet.olderAddressStarted], timeout: 5)
        wallet.invalidateReceiveInvoice()
        wallet.releaseOlderAddress()
        try await refresh.value
        XCTAssertNotEqual(wallet.bolt11, "ln-paid")
        try await wallet.refreshBip21(syncPublicPaykit: false)
        XCTAssertNotEqual(wallet.bolt11, "ln-paid")
    }

    func testPublicEndpointSyncDoesNotKeepCommittedInvoiceLoading() async throws {
        UserDefaults.standard.set(true, forKey: PublicPaykitService.publishingEnabledKey)
        UserDefaults.standard.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
        let wallet = GatedReceiveWallet()
        wallet.invoiceAmountSats = 2000
        wallet.gateEndpointSync = true
        let refresh = Task { try await wallet.refreshBip21(forceRefreshBolt11: true) }
        await fulfillment(of: [wallet.endpointSyncStarted], timeout: 5)
        XCTAssertTrue(wallet.hasCoherentReceiveInvoice)
        XCTAssertFalse(wallet.isReceiveInvoiceUpdating)
        wallet.releaseEndpointSync()
        try await refresh.value
    }

    func testFailedBackgroundForcedRefreshKeepsValidQr() async throws {
        let wallet = GatedReceiveWallet()
        seedReusableInvoice(wallet)
        wallet.reusableInvoice = true
        wallet.failNextInvoice = true
        try? await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false, reportsError: false)
        XCTAssertTrue(wallet.hasCoherentReceiveInvoice)
        XCTAssertNil(wallet.receiveInvoiceError)
    }

    func testInvalidationDuringNewInvoiceCreationStopsPublication() async throws {
        let wallet = GatedReceiveWallet()
        wallet.invoiceAmountSats = 1000
        let refresh = Task { try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false) }
        await fulfillment(of: [wallet.olderStarted], timeout: 5)
        wallet.invalidateReceiveInvoice()
        wallet.releaseOlderInvoice()
        try await refresh.value
        XCTAssertTrue(wallet.bolt11.isEmpty)
        XCTAssertFalse(wallet.isReceiveInvoiceUpdating)
        XCTAssertNil(wallet.receiveInvoiceError)
    }

    func testInvalidationDuringMetadataSaveStopsPublication() async throws {
        let wallet = taggedReceiveWallet()
        wallet.gateFirstHash = false
        wallet.gateFirstWrite = true
        let refresh = Task { try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false) }
        await fulfillment(of: [wallet.firstWriteStarted], timeout: 5)
        wallet.invalidateReceiveInvoice()
        wallet.releaseFirstWrite()
        try await refresh.value
        XCTAssertTrue(wallet.bolt11.isEmpty)
        XCTAssertFalse(wallet.isReceiveInvoiceUpdating)
    }

    func testDirectInvoiceClearDuringCachedRevalidationDoesNotRepublishIt() async throws {
        let wallet = GatedReceiveWallet()
        seedReusableInvoice(wallet)
        wallet.reusableInvoice = true
        wallet.gateFirstAddress = true
        let refresh = Task { try await wallet.refreshBip21(syncPublicPaykit: false) }
        await fulfillment(of: [wallet.olderAddressStarted], timeout: 5)
        wallet.bolt11 = ""
        wallet.releaseOlderAddress()
        try await refresh.value
        XCTAssertTrue(wallet.bolt11.isEmpty)
    }

    func testOlderEndpointSyncCompletionDoesNotClearNewerPendingRefresh() async throws {
        UserDefaults.standard.set(true, forKey: PublicPaykitService.publishingEnabledKey)
        UserDefaults.standard.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
        let wallet = GatedReceiveWallet()
        wallet.invoiceAmountSats = 2000
        wallet.gateEndpointSync = true
        let older = Task { try await wallet.refreshBip21(forceRefreshBolt11: true) }
        await fulfillment(of: [wallet.endpointSyncStarted], timeout: 5)
        wallet.invoiceAmountSats = 1000
        let newer = Task { try await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false) }
        await fulfillment(of: [wallet.olderStarted], timeout: 5)
        wallet.releaseEndpointSync()
        try await older.value
        XCTAssertTrue(wallet.isReceiveInvoiceUpdating)
        wallet.releaseOlderInvoice()
        try await newer.value
        XCTAssertFalse(wallet.isReceiveInvoiceUpdating)
    }

    func testFailedBackgroundRefreshWithoutCachedInvoiceReportsError() async throws {
        let wallet = GatedReceiveWallet()
        wallet.failNextInvoice = true
        try? await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false, reportsError: false)
        XCTAssertNotNil(wallet.receiveInvoiceError)
        XCTAssertFalse(wallet.isReceiveInvoiceUpdating)
    }

    func testFailedBackgroundRefreshWithExpiredCachedInvoiceReportsError() async throws {
        let wallet = GatedReceiveWallet()
        seedReusableInvoice(wallet)
        wallet.reusableInvoice = false
        wallet.failNextInvoice = true
        try? await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false, reportsError: false)
        XCTAssertNotNil(wallet.receiveInvoiceError)
    }

    func testFailedBackgroundRefreshWithChangedInputsReportsError() async throws {
        let wallet = GatedReceiveWallet()
        seedReusableInvoice(wallet)
        wallet.reusableInvoice = true
        wallet.invoiceNote = "new request"
        wallet.failNextInvoice = true
        try? await wallet.refreshBip21(forceRefreshBolt11: true, syncPublicPaykit: false, reportsError: false)
        XCTAssertNotNil(wallet.receiveInvoiceError)
    }

    private func seedReusableInvoice(_ wallet: GatedReceiveWallet) {
        wallet.invoiceAmountSats = 0
        wallet.invoiceNote = ""
        wallet.onchainAddress = "bcrt1qreceive"
        wallet.bolt11 = "ln-paid"
        wallet.bip21 = "bitcoin:bcrt1qreceive?lightning=ln-paid"
    }

    func testAutoRejectsOnchainOnlyAndMismatchedCachedInvoices() {
        let wallet = GatedReceiveWallet()
        wallet.bolt11 = "ln-newer"
        wallet.bip21 = "bitcoin:bcrt1qreceive"
        XCTAssertFalse(wallet.hasCoherentReceiveInvoice)
        wallet.bip21 = "bitcoin:bcrt1qreceive?lightning=ln-older"
        XCTAssertFalse(wallet.hasCoherentReceiveInvoice)
        wallet.bip21 = "bitcoin:bcrt1qreceive?lightning=ln-newer"
        XCTAssertTrue(wallet.hasCoherentReceiveInvoice)
    }

    func testAddressFailureCanBeRetried() async throws {
        let wallet = GatedReceiveWallet()
        wallet.invoiceAmountSats = 2000
        wallet.failNextAddress = true
        do { try await wallet.refreshBip21(syncPublicPaykit: false); XCTFail("Expected address failure") } catch {}
        XCTAssertNotNil(wallet.receiveInvoiceError)
        XCTAssertFalse(wallet.isReceiveInvoiceUpdating)
        try await wallet.refreshBip21(syncPublicPaykit: false)
        XCTAssertTrue(wallet.hasCoherentReceiveInvoice)
        XCTAssertNil(wallet.receiveInvoiceError)
    }
}

@MainActor
private final class StartupPublicationProfile: PubkyProfileManager {
    override func loadProfile() async {}
    override func checkAdoptedSource() async {}
}

@MainActor
private final class GatedReceiveWallet: WalletViewModel {
    let olderStarted = XCTestExpectation(description: "Older invoice suspended")
    private var olderInvoice: CheckedContinuation<String, Never>?
    var failNextInvoice = false
    var failNextAddress = false
    var gateFirstAddress = false
    var gateSecondAddress = false
    let endpointAddressStarted = XCTestExpectation(description: "Endpoint address suspended")
    private var endpointAddress: CheckedContinuation<String, Never>?
    var addressCallCount = 0
    let olderAddressStarted = XCTestExpectation(description: "Older address suspended")
    private var olderAddress: CheckedContinuation<String, Never>?

    var reusableInvoice: Bool?
    var gateEndpointSync = false
    var endpointSyncCount = 0
    var failPublicEndpointRefresh = false
    var stubPublicEndpoints = false
    var publicEndpointAddress = ""
    var replaceEmptyPublicInvoice = false
    var invoiceCreation: (() async throws -> String)?
    var beforePublicEndpointRefresh: (() async -> Void)?
    var afterPublicEndpointSnapshot: (() async -> Void)?
    var beforeReceiveAddress: (() async -> Void)?
    var applyPublicEndpoints: (([PublicPaykitService.Endpoint]) async throws -> Void)?
    var publicationRefreshModes: [Bool] = []
    var usableChannels: Bool?
    let endpointSyncStarted = XCTestExpectation(description: "Public endpoint sync suspended")
    private var endpointSync: CheckedContinuation<Void, Never>?

    override var hasUsableChannels: Bool {
        usableChannels ?? super.hasUsableChannels
    }

    override func refreshAndSyncState() async {}
    override func waitForNodeToRun(timeoutSeconds: Double = 10.0) async -> Bool {
        true
    }

    override func publishPublicPaykitEndpoints(refreshIfNeeded: Bool, isSessionCurrent: @escaping @MainActor () -> Bool) async throws {
        guard isSessionCurrent() else { return }
        guard let applyPublicEndpoints else {
            return try await super.publishPublicPaykitEndpoints(refreshIfNeeded: refreshIfNeeded, isSessionCurrent: isSessionCurrent)
        }
        publicationRefreshModes.append(refreshIfNeeded)
        if refreshIfNeeded {
            try await PublicPaykitService.syncPublishedEndpoints(
                wallet: self, publish: true, isSessionCurrent: isSessionCurrent, syncApp: {}, applyEndpoints: applyPublicEndpoints
            )
        } else {
            try await PublicPaykitService.syncCurrentPublishedEndpoints(
                wallet: self, isSessionCurrent: isSessionCurrent, syncApp: {}, applyEndpoints: applyPublicEndpoints
            )
        }
    }

    override func isReceiveInvoiceReusable(_ invoice: String) async throws -> Bool {
        if let reusableInvoice { return reusableInvoice }
        return try await super.isReceiveInvoiceReusable(invoice)
    }

    override func syncReceivePublicPaykitEndpoints(isSessionCurrent: @escaping @MainActor () -> Bool) async throws {
        if applyPublicEndpoints != nil {
            return try await super.syncReceivePublicPaykitEndpoints(isSessionCurrent: isSessionCurrent)
        }
        endpointSyncCount += 1
        if gateEndpointSync {
            await withCheckedContinuation {
                endpointSync = $0
                endpointSyncStarted.fulfill()
            }
        }
    }

    override func refreshPublicPaykitEndpoints(
        forceRefreshBolt11: Bool = false,
        includeOnchain: Bool = true,
        includeLightning: Bool = true
    ) async throws -> (onchainAddress: String, bolt11: String) {
        await beforePublicEndpointRefresh?()
        if failPublicEndpointRefresh { throw TestError.failed }
        if stubPublicEndpoints {
            if replaceEmptyPublicInvoice, forceRefreshBolt11 || publicPaykitBolt11.isEmpty {
                publicPaykitBolt11 = "ln-current"
            }
            let invoice = publicPaykitBolt11
            await afterPublicEndpointSnapshot?()
            return (publicEndpointAddress, invoice)
        }
        return try await super.refreshPublicPaykitEndpoints(
            forceRefreshBolt11: forceRefreshBolt11, includeOnchain: includeOnchain, includeLightning: includeLightning
        )
    }

    func releaseEndpointSync() {
        endpointSync?.resume()
        endpointSync = nil
    }

    override func paymentId() async -> String? { nil }
    override func persistPreActivityMetadata(tags: [String] = []) async {}
    override func persistPreActivityMetadata(paymentId: String, paymentHash: String?, address: String, tags: [String]) async {}
    override func canCreateReceiveLightningInvoice(amountSats: UInt64?) -> Bool { true }
    override func refreshReusableOnchainAddress() async throws -> String {
        await beforeReceiveAddress?()
        if failNextAddress { failNextAddress = false; throw TestError.failed }
        addressCallCount += 1
        if gateFirstAddress, addressCallCount == 1 {
            return await withCheckedContinuation {
                olderAddress = $0
                olderAddressStarted.fulfill()
            }
        }
        if gateSecondAddress, addressCallCount == 2 {
            return await withCheckedContinuation {
                endpointAddress = $0
                endpointAddressStarted.fulfill()
            }
        }
        return "bcrt1qreceive"
    }

    override func createInvoice(amountSats: UInt64? = nil, note: String, expirySecs: UInt32? = nil) async throws -> String {
        if let invoiceCreation { return try await invoiceCreation() }
        if failNextInvoice { failNextInvoice = false; throw TestError.failed }
        if amountSats == 1000 {
            return await withCheckedContinuation { continuation in
                olderInvoice = continuation
                olderStarted.fulfill()
            }
        }
        return "ln-newer"
    }

    func releaseOlderInvoice() {
        olderInvoice?.resume(returning: "ln-older")
        olderInvoice = nil
    }

    func releaseOlderAddress() {
        olderAddress?.resume(returning: "bcrt1qolder")
        olderAddress = nil
    }

    func releaseEndpointAddress() {
        endpointAddress?.resume(returning: "bcrt1qendpoint")
        endpointAddress = nil
    }

    private enum TestError: Error { case failed }
}

@MainActor
private final class PublicationGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ description: String) {
        started = XCTestExpectation(description: description)
    }

    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class TaggedReceiveWallet: WalletViewModel {
    let firstHashStarted = XCTestExpectation(description: "Older invoice hash suspended")
    var metadata: [String: [String]] = ["ln-initial": ["Lunch"]]
    var metadataAddresses = ["ln-initial": "bcrt1qreceive"]
    private var firstHash: CheckedContinuation<String?, Never>?
    let firstWriteStarted = XCTestExpectation(description: "Older metadata save suspended")
    var gateFirstHash = true
    var gateFirstWrite = false
    private var firstWrite: CheckedContinuation<Void, Never>?
    private var invoiceCount = 0

    override func paymentId() async -> String? { bolt11.isEmpty ? "initial" : bolt11 }
    var addressReads = 0
    override func receiveInvoiceTags(paymentId: String, searchByAddress: Bool = false) async -> [String]? {
        if searchByAddress {
            addressReads += 1
            guard let key = metadataAddresses.first(where: { $0.value == paymentId })?.key else { return nil }
            return metadata[key]
        }
        return metadata[paymentId]
    }

    override func refreshReusableOnchainAddress() async throws -> String { "bcrt1qreceive" }
    override func canCreateReceiveLightningInvoice(amountSats: UInt64?) -> Bool { true }
    override func createInvoice(amountSats: UInt64? = nil, note: String, expirySecs: UInt32? = nil) async throws -> String {
        invoiceCount += 1
        return invoiceCount == 1 ? "ln-first" : "ln-second"
    }

    override func receiveInvoicePaymentHash(invoice: String) async -> String? {
        if invoice == "ln-first", gateFirstHash {
            return await withCheckedContinuation {
                firstHash = $0
                firstHashStarted.fulfill()
            }
        }
        return invoice
    }

    override func persistPreActivityMetadata(paymentId: String, paymentHash: String?, address: String, tags: [String]) async {
        for key in metadataAddresses.filter({ $0.value == address }).map(\.key) {
            metadata.removeValue(forKey: key)
            metadataAddresses.removeValue(forKey: key)
        }
        metadata[paymentId] = tags
        metadataAddresses[paymentId] = address
        if paymentId == "ln-first", gateFirstWrite {
            await withCheckedContinuation {
                firstWrite = $0
                firstWriteStarted.fulfill()
            }
        }
    }

    override func mutateReceiveMetadataTags(paymentId: String?, address: String, mutation: Bitkit.ReceiveTagMutation) async throws {
        let exactKey = paymentId.flatMap { metadata[$0] == nil ? nil : $0 }
        guard let key = exactKey ?? metadataAddresses.first(where: { $0.value == address })?.key else { throw TestError.missingMetadata }
        switch mutation {
        case let .add(tags): metadata[key] = Array(Set((metadata[key] ?? []) + tags)).sorted()
        case let .remove(tags): metadata[key] = metadata[key]?.filter { !tags.contains($0) }
        case .reset: metadata[key] = []
        }
    }

    private enum TestError: Error { case missingMetadata }

    func releaseFirstWrite() {
        firstWrite?.resume()
        firstWrite = nil
    }

    func releaseFirstHash() {
        firstHash?.resume(returning: "ln-first")
        firstHash = nil
    }
}
