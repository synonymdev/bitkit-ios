@testable import Bitkit
import Foundation
import LDKNode
import XCTest

final class PublicPaykitServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // `clearPaykitDefaults()` removes seven live keys, including the bolt11 the app published to
        // the user's homeserver along with its payment hash and expiry.
        snapshotAppDefaultsDomain()
        clearPaykitDefaults()
    }

    func testParseEndpointReadsSpecPayloadObject() {
        let endpoint = PublicPaykitService.parseEndpoint(
            methodId: "btc-lightning-bolt11",
            endpointData: #"{"value":"lnbc1example","min":"1000","max":"2000"}"#
        )

        XCTAssertEqual(endpoint?.methodId, .bitcoinLightningBolt11)
        XCTAssertEqual(endpoint?.value, "lnbc1example")
        XCTAssertEqual(endpoint?.min, "1000")
        XCTAssertEqual(endpoint?.max, "2000")
    }

    func testParseEndpointRejectsRawStringPayload() {
        let endpoint = PublicPaykitService.parseEndpoint(
            methodId: "btc-bitcoin-p2wpkh",
            endpointData: "bc1qexampleaddress"
        )

        XCTAssertNil(endpoint)
    }

    func testParseEndpointRejectsUnsupportedMethodId() {
        let endpoint = PublicPaykitService.parseEndpoint(
            methodId: "btc-lightning-bolt12",
            endpointData: #"{"value":"anything"}"#
        )

        XCTAssertNil(endpoint)
    }

    func testParseEndpointReadsPaykyLnurlMethodId() {
        let endpoint = PublicPaykitService.parseEndpoint(
            methodId: "btc-lightning-lnurl",
            endpointData: #"{"value":"lnurl1example"}"#
        )

        XCTAssertEqual(endpoint?.methodId, .bitcoinLightningLnurl)
        XCTAssertEqual(endpoint?.value, "lnurl1example")
    }

    func testParseEndpointReadsNetworkSpecificOnchainMethodIds() {
        XCTAssertEqual(
            PublicPaykitService.parseEndpoint(
                methodId: "btc-testnet-p2wpkh",
                endpointData: #"{"value":"tb1qexample"}"#,
                network: .testnet
            )?.methodId,
            .testnetOnchainP2wpkh
        )
        XCTAssertEqual(
            PublicPaykitService.parseEndpoint(
                methodId: "btc-regtest-p2tr",
                endpointData: #"{"value":"bcrt1pexample"}"#,
                network: .regtest
            )?.methodId,
            .regtestOnchainP2tr
        )
    }

    func testParseEndpointRejectsUnsupportedLnurlMethodId() {
        let endpoint = PublicPaykitService.parseEndpoint(
            methodId: "btc-lightning-lnurl-pay",
            endpointData: #"{"value":"lnurl1example"}"#
        )

        XCTAssertNil(endpoint)
    }

    func testKnownMethodIdsFollowPaymentEndpointIdentifierSpec() {
        let specPattern = #"^[a-z0-9]+-[a-z0-9]+-[a-z0-9]+$"#

        for methodId in PublicPaykitService.MethodId.allCases {
            XCTAssertNotNil(methodId.rawValue.range(of: specPattern, options: .regularExpression), "\(methodId.rawValue) must be asset-rail-endpoint")
        }
    }

    func testSerializePayloadWrapsValueInJsonObject() throws {
        let payload = try PublicPaykitService.serializePayload(value: "  lnbc1invoice  ")
        let json = try XCTUnwrap(payload.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: String])

        XCTAssertEqual(object["value"], "lnbc1invoice")
        XCTAssertEqual(object.count, 1)
    }

    func testPaymentRequestCombinesOnchainAndBolt11Endpoints() {
        let request = PublicPaykitService.paymentRequest(from: [
            endpoint(.bitcoinLightningBolt11, value: "lnbc1invoice"),
            endpoint(.bitcoinOnchainP2wpkh, value: "bc1qaddress"),
        ])

        XCTAssertEqual(request, "bitcoin:bc1qaddress?lightning=lnbc1invoice")
    }

    func testPaymentRequestPercentEncodesLightningParameter() {
        let request = PublicPaykitService.paymentRequest(from: [
            endpoint(.bitcoinLightningBolt11, value: "lnbc1invoice?amount=1&label=test"),
            endpoint(.bitcoinOnchainP2wpkh, value: "bc1qaddress"),
        ])

        XCTAssertEqual(request, "bitcoin:bc1qaddress?lightning=lnbc1invoice%3Famount%3D1%26label%3Dtest")
    }

    func testPaymentRequestPrefersTaprootWhenMultipleOnchainEndpointsExist() {
        let request = PublicPaykitService.paymentRequest(from: [
            endpoint(.bitcoinLightningBolt11, value: "lnbc1invoice"),
            endpoint(.bitcoinOnchainP2pkh, value: "1legacy"),
            endpoint(.bitcoinOnchainP2wpkh, value: "bc1qsegwit"),
            endpoint(.bitcoinOnchainP2tr, value: "bc1ptaproot"),
        ])

        XCTAssertEqual(request, "bitcoin:bc1ptaproot?lightning=lnbc1invoice")
    }

    func testPaymentRequestFallsBackToPreferredEndpointWhenCombinedRequestIsNotAvailable() {
        let request = PublicPaykitService.paymentRequest(from: [
            endpoint(.bitcoinLightningBolt11, value: "lnbc1invoice"),
        ])

        XCTAssertEqual(request, "lnbc1invoice")
    }

    func testPaymentRequestFallsBackToLnurlOnlyEndpoint() {
        let request = PublicPaykitService.paymentRequest(from: [
            endpoint(.bitcoinLightningLnurl, value: "lnurl1example"),
        ])

        XCTAssertEqual(request, "lnurl1example")
    }

    func testOnchainMethodIdUsesAddressPrefixAndNetwork() {
        XCTAssertEqual(PublicPaykitService.onchainMethodId(for: "bc1pexample", network: .bitcoin), .bitcoinOnchainP2tr)
        XCTAssertEqual(PublicPaykitService.onchainMethodId(for: "tb1qexample", network: .testnet), .testnetOnchainP2wpkh)
        XCTAssertEqual(PublicPaykitService.onchainMethodId(for: "bcrt1qexample", network: .regtest), .regtestOnchainP2wpkh)
        XCTAssertEqual(PublicPaykitService.onchainMethodId(for: "3Example", network: .bitcoin), .bitcoinOnchainP2sh)
        XCTAssertEqual(PublicPaykitService.onchainMethodId(for: "2Example", network: .regtest), .regtestOnchainP2sh)
        XCTAssertEqual(PublicPaykitService.onchainMethodId(for: "1Example", network: .bitcoin), .bitcoinOnchainP2pkh)
    }

    func testPaymentLaunchResultFailureMessageKeys() {
        XCTAssertNil(
            PublicPaykitPaymentLaunchResult.opened(
                paymentRequest: "bitcoin:bcrt1ptest",
                privatePaymentContext: nil
            ).contactPaymentFailureMessageKey
        )
        XCTAssertEqual(PublicPaykitPaymentLaunchResult.noEndpoint.contactPaymentFailureMessageKey, "slashtags__error_pay_empty_msg")
        XCTAssertEqual(PublicPaykitPaymentLaunchResult.notOpened.contactPaymentFailureMessageKey, "slashtags__error_pay_not_opened_msg")
        XCTAssertEqual(PublicPaykitPaymentLaunchResult.privateLinkPending.contactPaymentFailureMessageKey, "slashtags__error_pay_empty_msg")
        XCTAssertEqual(
            PublicPaykitPaymentLaunchResult.waitingForUpdatedPaymentList.contactPaymentFailureMessageKey,
            "slashtags__error_pay_empty_msg"
        )
    }

    func testPaymentLaunchResultHasReasonSpecificIncomingRequestFailures() {
        XCTAssertNil(
            PublicPaykitPaymentLaunchResult.opened(
                paymentRequest: "bitcoin:bcrt1ptest",
                privatePaymentContext: nil
            ).incomingPaymentRequestFailureReason
        )
        XCTAssertEqual(PublicPaykitPaymentLaunchResult.noEndpoint.incomingPaymentRequestFailureReason, .noSupportedEndpoint)
        XCTAssertEqual(PublicPaykitPaymentLaunchResult.notOpened.incomingPaymentRequestFailureReason, .endpointNotPayable)
        XCTAssertEqual(PublicPaykitPaymentLaunchResult.privateLinkPending.incomingPaymentRequestFailureReason, .paymentDetailsPending)
        XCTAssertEqual(
            PublicPaykitPaymentLaunchResult.waitingForUpdatedPaymentList.incomingPaymentRequestFailureReason,
            .paymentDetailsPending
        )
    }

    func testIncomingRequestFailureReasonsHaveStableCategories() {
        XCTAssertEqual(IncomingPaykitPaymentRequestFailureReason.noSupportedEndpoint.category, "resolution")
        XCTAssertEqual(IncomingPaykitPaymentRequestFailureReason.endpointNotPayable.category, "resolution")
        XCTAssertEqual(IncomingPaykitPaymentRequestFailureReason.paymentDetailsPending.category, "resolution")
        XCTAssertEqual(IncomingPaykitPaymentRequestFailureReason.resolutionFailed.category, "resolution")
        XCTAssertEqual(IncomingPaykitPaymentRequestFailureReason.invalidPaymentTarget.category, "presentation")
        XCTAssertEqual(IncomingPaykitPaymentRequestFailureReason.paymentTargetNotRoutable.category, "presentation")
        XCTAssertEqual(IncomingPaykitPaymentRequestFailureReason.requestExpired.category, "presentation")
    }

    func testAppSceneFeedbackMapsRequestedExpirationToExpiredDiagnosticsAndToast() {
        let feedback = IncomingPaykitPaymentRequestPresentationFeedback(
            deferral: .requestExpired(wasRequested: true),
            fallbackReason: .resolutionFailed
        )

        XCTAssertEqual(feedback.diagnosticReason, .requestExpired)
        XCTAssertEqual(feedback.diagnosticReason.rawValue, "request_expired")
        XCTAssertTrue(feedback.isTerminal)
        XCTAssertEqual(feedback.toast?.titleKey, "wallet__payment_request")
        XCTAssertEqual(feedback.toast?.descriptionKey, "wallet__payment_request_expired")
        XCTAssertEqual(feedback.toast?.accessibilityIdentifier, "PaymentRequestExpiredToast")
        XCTAssertEqual(feedback.toast?.isInformational, false)
    }

    func testAppSceneFeedbackMapsRequestedPrivateLinkRecoveryToInformationalToast() {
        let feedback = IncomingPaykitPaymentRequestPresentationFeedback(paymentDetailsPendingWasRequested: true)

        XCTAssertEqual(feedback.diagnosticReason, .paymentDetailsPending)
        XCTAssertFalse(feedback.isTerminal)
        XCTAssertTrue(feedback.shouldLogDiagnostic)
        XCTAssertEqual(feedback.toast?.titleKey, "wallet__payment_request")
        XCTAssertEqual(feedback.toast?.descriptionKey, "wallet__payment_request_waiting_for_details")
        XCTAssertEqual(feedback.toast?.accessibilityIdentifier, "PaymentRequestWaitingForDetailsToast")
        XCTAssertEqual(feedback.toast?.isInformational, true)
    }

    func testAutomaticPrivateLinkRecoveryFeedbackDoesNotShowToast() {
        let feedback = IncomingPaykitPaymentRequestPresentationFeedback(paymentDetailsPendingWasRequested: false)

        XCTAssertEqual(feedback.diagnosticReason, .paymentDetailsPending)
        XCTAssertTrue(feedback.shouldLogDiagnostic)
        XCTAssertNil(feedback.toast)
    }

    func testPayableEndpointsFiltersInvalidDecodedEndpoints() async {
        let payable = await PublicPaykitService.payableEndpoints(from: [
            endpoint(.bitcoinLightningBolt11, value: "not-a-bolt11"),
            endpoint(.bitcoinOnchainP2tr, value: "not-an-address"),
        ])

        XCTAssertTrue(payable.isEmpty)
    }

    func testBuildAvailabilityMarksPublicCleanupPendingForPublishedPublicState() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(true, forKey: ContactPaymentsService.confirmedPreferenceKey)

            PaykitFeatureFlags.enforceBuildAvailability(defaults: defaults, isUIEnabled: false)

            XCTAssertTrue(defaults.bool(forKey: PublicPaykitService.cleanupPendingKey))
            XCTAssertFalse(defaults.bool(forKey: ContactPaymentsService.confirmedPreferenceKey))
            XCTAssertFalse(defaults.bool(forKey: PublicPaykitService.publishingEnabledKey))
        }
    }

    func testPendingReconciliationHandlesWriterProducedSharingStates() throws {
        let expectedModes: [(publicEnabled: Bool, privateEnabled: Bool, mode: PublicPaykitService.PendingReconciliationMode)] = [
            (true, true, .publishEndpoints),
            (true, false, .publishEndpoints),
            (false, true, .removePublishedState),
            (false, false, .removePublishedState),
        ]

        for expected in expectedModes {
            try withIsolatedDefaults { defaults in
                defaults.set(expected.publicEnabled, forKey: PublicPaykitService.publishingEnabledKey)
                defaults.set(expected.privateEnabled, forKey: PrivatePaykitService.publishingEnabledKey)

                XCTAssertEqual(PublicPaykitService.pendingReconciliationMode(defaults: defaults), expected.mode)
            }
        }
    }

    @MainActor
    func testPublicationSyncsAppBeforeApplyingPreparedEndpoints() async throws {
        let desiredEndpoints = [endpoint(.bitcoinOnchainP2wpkh, value: "bc1qaddress")]
        var calls: [String] = []

        try await PublicPaykitService.syncPublishedEndpoints(
            publish: true,
            buildEndpoints: {
                calls.append("build")
                return desiredEndpoints
            },
            syncApp: { calls.append("app") },
            applyEndpoints: {
                calls.append("apply")
                XCTAssertEqual($0, desiredEndpoints)
            }
        )

        XCTAssertEqual(calls, ["build", "app", "apply"])
    }

    @MainActor
    func testPublicationFinishesAdmittedAppWriteButSkipsEndpointsAfterSessionEnds() async throws {
        for cancelTask in [false, true] {
            var isCurrent = true
            var calls: [String] = []
            var finishWrite: CheckedContinuation<Void, Never>?
            let admitted = expectation(description: "App write admitted")
            let publication = Task {
                try await PublicPaykitService.syncPublishedEndpoints(
                    publish: true,
                    isSessionCurrent: { isCurrent && !Task.isCancelled },
                    buildEndpoints: { [self.endpoint(.bitcoinOnchainP2wpkh, value: "bc1qaddress")] },
                    syncApp: {
                        calls.append("app")
                        await withCheckedContinuation {
                            finishWrite = $0
                            admitted.fulfill()
                        }
                        calls.append("app-finished")
                    },
                    applyEndpoints: { _ in calls.append("endpoints") }
                )
            }
            await fulfillment(of: [admitted], timeout: 2)
            if cancelTask {
                publication.cancel()
            } else {
                isCurrent = false
            }
            finishWrite?.resume()
            do {
                try await publication.value
                XCTFail("Expected the ended session to stop the next write")
            } catch PubkyServiceError.sessionNotActive {}
            XCTAssertEqual(calls, ["app", "app-finished"])
        }
    }

    @MainActor
    func testPublicationSyncsAppWhenEndpointBuildFails() async {
        var calls: [String] = []

        do {
            try await PublicPaykitService.syncPublishedEndpoints(
                publish: true,
                buildEndpoints: {
                    calls.append("build")
                    throw PublicPaykitError.walletNotReady
                },
                syncApp: { calls.append("app") },
                applyEndpoints: { _ in XCTFail("Failed endpoint construction must not publish endpoints") }
            )
            XCTFail("Expected endpoint construction to fail")
        } catch {
            guard case PublicPaykitError.walletNotReady = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(calls, ["build", "app"])
    }

    @MainActor
    func testUsdtPreparationDoesNotBlockLightningRenewalAndTracksCurrentWallet() async throws {
        try XCTSkipUnless(Env.isUsdtEnabled)
        UserDefaults.standard.set(true, forKey: PaykitFeatureFlags.uiEnabledKey)
        UserDefaults.standard.set(true, forKey: ContactPaymentsService.confirmedPreferenceKey)
        UserDefaults.standard.set(true, forKey: PublicPaykitService.publishingEnabledKey)
        UserDefaults.standard.set(false, forKey: PublicPaykitService.onchainPaymentOptionEnabledKey)
        UserDefaults.standard.set(true, forKey: PublicPaykitService.lightningPaymentOptionEnabledKey)
        UserDefaults.standard.set(true, forKey: PublicPaykitService.usdtPaymentOptionEnabledKey)
        UserDefaults.standard.set(UsdtPreference.enabled.rawValue, forKey: UsdtPreference.key)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var available = false
        var passphrase: String?
        var cancelled = false
        let manager = UsdtWalletManager(storageDirectory: directory, rpcUrl: nil, bundlerUrl: nil, loadCredentials: {
            if cancelled { throw CancellationError() }
            guard available else { throw PublicPaykitError.walletNotReady }
            return ("test test test test test test test test test test test junk", passphrase)
        })
        let wallet = EndpointPublicationWallet(usdtWallet: manager)
        wallet.publicPaykitBolt11 = "old-advertised-invoice"
        wallet.publicPaykitBolt11ExpiresAt = 0
        PublicPaykitService.setCleanupPending(false)
        var publications = [[PublicPaykitService.Endpoint]]()
        let publish = {
            try await PublicPaykitService.syncCurrentPublishedEndpoints(
                wallet: wallet, isSessionCurrent: { true }, syncApp: {},
                applyEndpoints: { publications.append($0) }
            )
        }
        try await publish()
        XCTAssertEqual(publications.last?.map(\.methodId), [.bitcoinLightningBolt11])
        XCTAssertEqual(publications.last?.first?.value, EndpointPublicationWallet.invoice)
        XCTAssertTrue(PublicPaykitService.isCleanupPending)

        let privateService = PrivatePaykitService()
        let contact = "pubky" + String(repeating: "y", count: 52)
        await privateService.setEndpointTestInvoice(
            .init(bolt11: "expired-invoice", paymentHash: "expired-hash", expiresAt: 0), publicKey: contact
        )
        let firstPrivate = try await privateService.buildLocalEndpoints(for: contact, wallet: wallet)
        XCTAssertEqual(firstPrivate.map(\.methodId), [.bitcoinLightningBolt11])
        XCTAssertEqual(firstPrivate.first?.value, EndpointPublicationWallet.invoice)

        available = true
        try await publish()
        XCTAssertFalse(PublicPaykitService.isCleanupPending)
        let privateEndpoints = try await privateService.buildLocalEndpoints(for: contact, wallet: wallet)
        XCTAssertEqual(privateEndpoints.map(\.methodId), [.bitcoinLightningBolt11, .usdtArbitrum])
        let originalAddress = try XCTUnwrap(privateEndpoints.last?.value)
        XCTAssertEqual(publications.last?.last?.value, originalAddress)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        // Renewal uses fresh Lightning details without opening the USDT database.
        wallet.publicPaykitBolt11 = "another-expired-invoice"
        wallet.publicPaykitBolt11ExpiresAt = 0
        try await publish()
        let renewed = try await privateService.buildLocalEndpoints(for: contact, wallet: wallet, forceRefreshLightning: true)
        XCTAssertEqual(renewed.last?.value, originalAddress)
        XCTAssertEqual(publications.last?.first?.value, EndpointPublicationWallet.invoice)
        XCTAssertEqual(publications.last?.last?.value, originalAddress)

        passphrase = "another wallet"
        available = false
        try await publish()
        let unavailable = try await privateService.buildLocalEndpoints(for: contact, wallet: wallet)
        XCTAssertEqual(unavailable.map(\.methodId), [.bitcoinLightningBolt11])
        XCTAssertEqual(publications.last?.map(\.methodId), [.bitcoinLightningBolt11])
        XCTAssertTrue(PublicPaykitService.isCleanupPending)
        available = true
        try await publish()
        let changed = try await privateService.buildLocalEndpoints(for: contact, wallet: wallet)
        XCTAssertNotEqual(changed.last?.value, originalAddress)
        XCTAssertEqual(publications.last?.last?.value, changed.last?.value)

        UserDefaults.standard.set(false, forKey: PublicPaykitService.usdtPaymentOptionEnabledKey)
        cancelled = true
        try await publish()
        let disabled = try await privateService.buildLocalEndpoints(for: contact, wallet: wallet)
        XCTAssertEqual(disabled.map(\.methodId), [.bitcoinLightningBolt11])
        XCTAssertEqual(publications.last?.map(\.methodId), [.bitcoinLightningBolt11])
        XCTAssertFalse(PublicPaykitService.isCleanupPending)

        UserDefaults.standard.set(true, forKey: PublicPaykitService.usdtPaymentOptionEnabledKey)
        let publishedCount = publications.count
        do {
            try await publish()
            XCTFail("Cancelled publication must stop")
        } catch is CancellationError {}
        do {
            _ = try await privateService.buildLocalEndpoints(for: contact, wallet: wallet)
            XCTFail("Cancelled private preparation must stop")
        } catch is CancellationError {}
        XCTAssertEqual(publications.count, publishedCount)
    }

    private func endpoint(_ methodId: PublicPaykitService.MethodId, value: String) -> PublicPaykitService.Endpoint {
        PublicPaykitService.Endpoint(
            methodId: methodId,
            value: value,
            min: nil,
            max: nil,
            rawPayload: #"{"value":"\#(value)"}"#
        )
    }

    private func clearPaykitDefaults() {
        UserDefaults.standard.removeObject(forKey: PaykitFeatureFlags.uiEnabledKey)
        UserDefaults.standard.removeObject(forKey: PublicPaykitService.publishingEnabledKey)
        UserDefaults.standard.removeObject(forKey: PublicPaykitService.cleanupPendingKey)
        UserDefaults.standard.removeObject(forKey: ContactPaymentsService.confirmedPreferenceKey)
        UserDefaults.standard.removeObject(forKey: "publicPaykitBolt11")
        UserDefaults.standard.removeObject(forKey: "publicPaykitBolt11PaymentHash")
        UserDefaults.standard.removeObject(forKey: "publicPaykitBolt11ExpiresAt")
    }

    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "PublicPaykitServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}

@MainActor
private final class EndpointPublicationWallet: WalletViewModel {
    static let invoice =
        "lnbcrt200n1p5hn4c8dqqnp4qwrgh4a03djj2sl34465uwnxhva0gtpjm4u8kvzgc5jergrkm9syypp55lwcgfpkdwuknmekjgted72n0ddl5qtaha7knk7c9n7yrjr4auassp5jgqw0a9w33e2ta4j7gyjrvsvu0lv844w895305nd8spnknq3f2hq9qyysgqcqzp2xqyz5vqrzjq29gjy9sqjrrp48tz7hj2e5vm4l2dukc4csf2mn6qm32u3hted5leapyqqqqqqqtcsqqqqlgqqqqqqgq2qd2gk64eg2kfxtdaryrlh98hvu97jdaxz2ma7aeyuy2uy9vkn9x5qft47p9taju297xnrehva20xcfml7wacuv737xv3xjjzyrtplcxqpfpu9dt"

    override var hasUsableChannels: Bool {
        true
    }

    override func createInvoice(amountSats: UInt64? = nil, note: String, expirySecs: UInt32? = nil) async throws -> String {
        Self.invoice
    }
}

private extension PrivatePaykitService {
    func setEndpointTestInvoice(_ invoice: StoredInvoice, publicKey: String) {
        state.contacts[publicKey] = ContactState()
        state.contacts[publicKey]?.localInvoice = invoice
    }
}
