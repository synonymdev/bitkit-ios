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
    var beforePublicEndpointRefresh: (() async -> Void)?
    let endpointSyncStarted = XCTestExpectation(description: "Public endpoint sync suspended")
    private var endpointSync: CheckedContinuation<Void, Never>?

    override func isReceiveInvoiceReusable(_ invoice: String) async throws -> Bool {
        if let reusableInvoice { return reusableInvoice }
        return try await super.isReceiveInvoiceReusable(invoice)
    }

    override func syncReceivePublicPaykitEndpoints() async throws {
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
        if stubPublicEndpoints { return ("", publicPaykitBolt11) }
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
