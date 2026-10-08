@testable import Bitkit
import LDKNode
import Paykit
import XCTest

private let approvalTestXpub =
    "tpubDDWohsp5dx2iMJ9N7iHbgAEDhH4BJB9NWW1fEW3yA3AFNDREmpzteCXNqppMLUmKFY5q5e3" +
    "PXtS5CuqWCQbYcGhpPqYAgQSYdwknW9J6sQv"
private let approvalTestClientPublicKey = "5jsjx1o6fzu6aeeo697r3i5rx15zq41kikcye8wtwdqm4nb4tryo"

private func approvalTestAuthUrl(secret: String = "e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s") -> String {
    "pubkyauth://signin_grant?caps=\(PubkyAuthClaim.requiredCapabilities)" +
        "&relay=https://httprelay.pubky.app/inbox/&secret=\(secret)" +
        "&cid=paykit.test&cpk=\(approvalTestClientPublicKey)" +
        "&x-bitkit-claim=watch-only-account-v1"
}

private func ordinaryApprovalTestAuthUrl() -> String {
    "pubkyauth://signin_grant?caps=/pub/example/:rw&relay=https://httprelay.pubky.app/inbox/" +
        "&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s" +
        "&cid=paykit.test&cpk=\(approvalTestClientPublicKey)"
}

final class PubkyAuthApprovalSheetTests: XCTestCase {
    @MainActor
    func testGrantSignupAuthorizesTheRequestedAppThroughTheGrantApi() async throws {
        let url = ordinaryApprovalTestAuthUrl().replacingOccurrences(of: "signin_grant", with: "signup_grant") +
            "&hs=\(approvalTestClientPublicKey)&st=invite"
        let request = try PubkyAuthRequest.parse(url: url)
        var approved = false

        try await PubkyService.approveSignupAuthorization(
            request: request,
            secretKeyHex: "derived-secret",
            ordinaryApproval: { authUrl, capabilities, clientID, secretKey in
                XCTAssertEqual(authUrl, url)
                XCTAssertEqual(capabilities, request.capabilities)
                XCTAssertEqual(clientID, "paykit.test")
                XCTAssertEqual(secretKey, "derived-secret")
                approved = true
            },
            ringApproval: { _, _ in XCTFail("Grant signup must use the grant API") }
        )

        XCTAssertTrue(approved)
        XCTAssertEqual(PubkyAuthApprovalSheet.initialState(for: request), .authorize)
    }

    @MainActor
    func testReceivingDetailsShareExactlyTheRequestedAssets() async throws {
        let endpoint = try PaykitUsdt.endpoint(address: "0x1111111111111111111111111111111111111111")
        for claim in [PubkyAuthClaim.usdtAddressV1, .bitcoinAndUsdt] {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "EarnSharing.\(UUID().uuidString)"))
            let manager = Bitkit.WatchOnlyAccountManager(defaults: defaults, node: ApprovalFakeWatchOnlyAccountNode())
            let url = approvalTestAuthUrl().replacingOccurrences(of: "watch-only-account-v1", with: claim.rawValue)
            let request = try PubkyAuthRequest.parse(url: url)
            XCTAssertEqual(PubkyAuthApprovalSheet.initialState(for: request), .watchOnlyConsent)
            var shared: [String: Any]?
            try await PubkyService.approveAuthRequest(
                request: request, authUrl: url, accountName: "Earn", secretKeyHex: "secret", accountManager: manager,
                approvedUsdtAddress: endpoint.value, usdtEndpoint: { endpoint },
                ordinaryApproval: { _, _, _, _ in XCTFail("A receiving-details request requires a companion claim") },
                companionApproval: { _, _, type, payload, _ in
                    XCTAssertEqual(type, claim)
                    shared = try JSONSerialization.jsonObject(with: XCTUnwrap(payload)) as? [String: Any]
                }
            )
            let details = try XCTUnwrap(shared)
            let usdt = try XCTUnwrap(details["usdt-arbitrum-address"] as? [String: String])
            XCTAssertEqual(usdt, ["value": endpoint.value, "chain_id": PaykitUsdt.chainId, "token": PaykitUsdt.token])
            XCTAssertEqual(Set(details.keys), claim.sharesBitcoin ? ["bitcoin_account", "usdt-arbitrum-address"] : ["usdt-arbitrum-address"])
            XCTAssertEqual(manager.accounts.count, claim.sharesBitcoin ? 1 : 0)
            if claim.sharesBitcoin {
                let bitcoin = try XCTUnwrap(details["bitcoin_account"] as? [String: Any])
                XCTAssertEqual(bitcoin["xpub"] as? String, manager.accounts.first?.xpub)
                XCTAssertEqual(bitcoin["account_index"] as? UInt32, manager.accounts.first?.accountIndex)
                XCTAssertEqual(manager.accounts.first?.setupState, .active)
            }
        }
    }

    @MainActor
    func testReceivingDetailsRequireTheReviewedAddress() async throws {
        let endpoint = try PaykitUsdt.endpoint(address: "0x1111111111111111111111111111111111111111")
        let url = approvalTestAuthUrl().replacingOccurrences(of: "watch-only-account-v1", with: "usdt-address-v1")
        let request = try PubkyAuthRequest.parse(url: url)
        for approvedAddress in ["0x2222222222222222222222222222222222222222"] {
            do {
                try await PubkyService.approveAuthRequest(
                    request: request, authUrl: url, accountName: "Earn", secretKeyHex: "secret",
                    approvedUsdtAddress: approvedAddress, usdtEndpoint: { endpoint },
                    companionApproval: { _, _, _, _, _ in XCTFail("Unapproved details must not be sent") }
                )
                XCTFail("Expected approval to require the reviewed address")
            } catch {
                XCTAssertEqual(error as? PubkyAuthRequestError, .invalidPaymentDetails)
            }
        }
    }

    @MainActor
    func testOptionalUsdtCanBeDeclinedWithoutLoadingAnAddress() async throws {
        let url = approvalTestAuthUrl().replacingOccurrences(of: "watch-only-account-v1", with: "paykit-access-v1.usdt-address-v1")
        let request = try PubkyAuthRequest.parse(url: url)
        var shared: Data?
        try await PubkyService.approveAuthRequest(
            request: request, authUrl: url, accountName: "Earn", secretKeyHex: "secret",
            approvedUsdtAddress: nil,
            usdtEndpoint: { XCTFail("Declined permission must not read the wallet"); throw PubkyAuthRequestError.invalidPaymentDetails },
            companionApproval: { _, _, _, payload, _ in shared = payload }
        )
        let claim = try XCTUnwrap(request.bitkitClaim)
        let key = try PaykitIdentitySecretKey(bytes: Data(repeating: 11, count: 32), keyGeneration: 3)
        let encoded = try claim.encode(accountPayload: shared, paykitKey: key)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["paykit_access"])
        let access = try XCTUnwrap(json["paykit_access"] as? [String: Any])
        XCTAssertEqual(access["key_generation"] as? UInt64, 3)
        XCTAssertEqual(access["secret"] as? String, "CwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCws")
    }

    func testAuthDisplayPublicKeyOmitsPubkyPrefix() {
        XCTAssertEqual(pubkyAuthDisplayPublicKey("pubky3rsd123456789w5xg"), "3rsd...w5xg")
        XCTAssertEqual(pubkyAuthDisplayPublicKey("3rsd123456789w5xg"), "3rsd...w5xg")
        XCTAssertEqual(pubkyAuthDisplayPublicKey(nil), "")
    }

    @MainActor
    func testWatchOnlyRequestStartsWithSeparateConsentBeforeAuthorization() throws {
        let authUrl = approvalTestAuthUrl()
        let request = try PubkyAuthRequest.parse(url: authUrl)
        var state = PubkyAuthApprovalSheet.initialState(for: request)

        XCTAssertEqual(state, .watchOnlyConsent)
        XCTAssertTrue(state.approveWatchOnlyConsent())
        XCTAssertEqual(state, .authorize)
        XCTAssertFalse(state.approveWatchOnlyConsent())
    }

    func testOrdinaryRequestStartsAtNormalAuthorization() throws {
        let authUrl = ordinaryApprovalTestAuthUrl()
        let request = try PubkyAuthRequest.parse(url: authUrl)

        XCTAssertEqual(PubkyAuthApprovalSheet.initialState(for: request), .authorize)
    }

    @MainActor
    func testPaykitOnlyApprovalDoesNotCreateOrTrackAnAccount() async throws {
        let suiteName = "PubkyAuthApprovalSheetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let node = ApprovalFakeWatchOnlyAccountNode()
        let manager = Bitkit.WatchOnlyAccountManager(defaults: defaults, node: node)
        let authUrl = approvalTestAuthUrl().replacingOccurrences(of: "watch-only-account-v1", with: "paykit-access-v1")
        let request = try PubkyAuthRequest.parse(url: authUrl)
        XCTAssertEqual(PubkyAuthApprovalSheet.initialState(for: request), .authorize)
        var approved = false
        try await PubkyService.approveAuthRequest(
            request: request, authUrl: authUrl, accountName: "", secretKeyHex: "secret",
            accountManager: manager,
            ordinaryApproval: { _, _, _, _ in XCTFail("Paykit access requires explicit companion approval") },
            companionApproval: { _, _, claim, payload, _ in
                XCTAssertEqual(claim, .paykitAccessV1)
                XCTAssertNil(payload)
                approved = true
            }
        )
        XCTAssertTrue(approved)
        XCTAssertTrue(manager.accounts.isEmpty)
        XCTAssertTrue(node.trackingChanges.isEmpty)
        XCTAssertTrue(try Bitkit.WatchOnlyAccountStore.load(defaults: defaults).isEmpty)
    }

    @MainActor
    func testPaykitOnlyReconnectPreservesAccountThroughFailureAndRetry() async throws {
        let suiteName = "PubkyAuthApprovalSheetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let node = ApprovalFakeWatchOnlyAccountNode()
        let manager = Bitkit.WatchOnlyAccountManager(defaults: defaults, node: node)
        let firstUrl = approvalTestAuthUrl()
        try await PubkyService.approveAuthRequest(
            request: PubkyAuthRequest.parse(url: firstUrl), authUrl: firstUrl,
            accountName: "Original server", secretKeyHex: "secret", accountManager: manager,
            companionApproval: { _, _, _, _, _ in }
        )
        let original = try XCTUnwrap(manager.accounts.first)
        let snapshot = try Bitkit.WatchOnlyAccountStore.backupSnapshot(defaults: defaults)
        let reconnectUrl = approvalTestAuthUrl(secret: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
            .replacingOccurrences(of: "watch-only-account-v1", with: "paykit-access-v1")
        let reconnectRequest = try PubkyAuthRequest.parse(url: reconnectUrl)
        for failure in [ApprovalFakeError.deliveryFailed as Error, CancellationError()] {
            await XCTAssertThrowsErrorAsync {
                try await PubkyService.approveAuthRequest(
                    request: reconnectRequest, authUrl: reconnectUrl,
                    accountName: "Untrusted request name", secretKeyHex: "secret",
                    accountManager: manager,
                    companionApproval: { _, _, claim, payload, _ in
                        XCTAssertTrue(claim.includesPaykitAccess)
                        XCTAssertFalse(claim.includesWatchOnlyAccount)
                        XCTAssertNil(payload)
                        throw failure
                    }
                )
            }
            XCTAssertEqual(manager.accounts, [original])
            XCTAssertEqual(try Bitkit.WatchOnlyAccountStore.load(defaults: defaults), [original])
        }
        try await PubkyService.approveAuthRequest(
            request: reconnectRequest, authUrl: reconnectUrl,
            accountName: "Untrusted request name", secretKeyHex: "secret",
            accountManager: manager,
            companionApproval: { _, _, _, _, _ in }
        )
        XCTAssertEqual(manager.accounts, [original])
        XCTAssertEqual(node.trackingChanges, [true])
        XCTAssertEqual(try Bitkit.WatchOnlyAccountStore.backupSnapshot(defaults: defaults).allocationState, snapshot.allocationState)
    }

    @MainActor
    func testOrdinaryRequestUsesOrdinaryApproval() async throws {
        let authUrl = ordinaryApprovalTestAuthUrl()
        let request = try PubkyAuthRequest.parse(url: authUrl)
        var approvedCapabilities: String?
        var approvedClientID: String?

        try await PubkyService.approveAuthRequest(
            request: request,
            authUrl: authUrl,
            accountName: "",
            secretKeyHex: "secret",
            ordinaryApproval: { _, capabilities, clientID, _ in
                approvedCapabilities = capabilities
                approvedClientID = clientID
            },
            companionApproval: { _, _, _, _, _ in XCTFail("Ordinary auth must not deliver a companion claim") }
        )

        XCTAssertEqual(approvedCapabilities, "/pub/example/:rw")
        XCTAssertEqual(approvedClientID, "paykit.test")
    }

    func testResolvePubkyApprovalLocalAuthModePrefersPinWhenPinEnabled() {
        let mode = resolvePubkyApprovalLocalAuthMode(
            isPinEnabled: true,
            isBiometricEnabled: true,
            isBiometrySupported: true
        )

        XCTAssertEqual(mode, .authCheck)
    }

    func testResolvePubkyApprovalLocalAuthModeUsesBiometricsWhenPinDisabled() {
        let mode = resolvePubkyApprovalLocalAuthMode(
            isPinEnabled: false,
            isBiometricEnabled: true,
            isBiometrySupported: true
        )

        XCTAssertEqual(mode, .biometrics)
    }

    func testResolvePubkyApprovalLocalAuthModeUsesNoneWhenBiometricsDisabled() {
        let mode = resolvePubkyApprovalLocalAuthMode(
            isPinEnabled: false,
            isBiometricEnabled: false,
            isBiometrySupported: true
        )

        XCTAssertEqual(mode, .none)
    }

    func testResolvePubkyApprovalLocalAuthModeUsesNoneWhenBiometricsUnavailable() {
        let mode = resolvePubkyApprovalLocalAuthMode(
            isPinEnabled: false,
            isBiometricEnabled: true,
            isBiometrySupported: false
        )

        XCTAssertEqual(mode, .none)
    }

    @MainActor
    func testCompanionDeliveryFailureDoesNotApproveOrdinaryAuthOrActivateAccount() async throws {
        let suiteName = "PubkyAuthApprovalSheetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let authUrl = approvalTestAuthUrl()
        let request = try PubkyAuthRequest.parse(url: authUrl)
        let node = ApprovalFakeWatchOnlyAccountNode()
        let manager = Bitkit.WatchOnlyAccountManager(defaults: defaults, node: node)
        var ordinaryApprovalCount = 0
        var companionApprovalCount = 0

        do {
            try await PubkyService.approveAuthRequest(
                request: request,
                authUrl: authUrl,
                accountName: "Creator store",
                secretKeyHex: "secret",
                accountManager: manager,
                ordinaryApproval: { _, _, _, _ in ordinaryApprovalCount += 1 },
                companionApproval: { _, _, _, _, _ in
                    companionApprovalCount += 1
                    throw ApprovalFakeError.deliveryFailed
                }
            )
            XCTFail("Expected companion approval to fail")
        } catch ApprovalFakeError.deliveryFailed {}

        XCTAssertEqual(companionApprovalCount, 1)
        XCTAssertEqual(ordinaryApprovalCount, 0)
        XCTAssertEqual(manager.accounts.count, 1)
        XCTAssertEqual(manager.accounts.first?.setupState, .pendingDelivery)
        XCTAssertEqual(manager.accounts.first?.isTrackingEnabled, false)
        XCTAssertEqual(node.trackingChanges, [true, false])
    }

    @MainActor
    func testCompanionDeliverySuccessActivatesAndKeepsAccountTracked() async throws {
        let suiteName = "PubkyAuthApprovalSheetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let authUrl = approvalTestAuthUrl()
        let request = try PubkyAuthRequest.parse(url: authUrl)
        let node = ApprovalFakeWatchOnlyAccountNode()
        let manager = Bitkit.WatchOnlyAccountManager(defaults: defaults, node: node)

        try await PubkyService.approveAuthRequest(
            request: request,
            authUrl: authUrl,
            accountName: "Creator store",
            secretKeyHex: "secret",
            accountManager: manager,
            companionApproval: { _, _, _, _, _ in }
        )

        XCTAssertEqual(manager.accounts.first?.setupState, .active)
        XCTAssertEqual(manager.accounts.first?.isTrackingEnabled, true)
        XCTAssertEqual(node.trackingChanges, [true])
    }

    @MainActor
    func testApprovalStateBeginsAuthorizationOnlyOnce() {
        var state = PubkyAuthApprovalSheet.ApprovalState.authorize

        XCTAssertTrue(state.canDismiss)
        XCTAssertTrue(state.beginAuthorization())
        XCTAssertEqual(state, .authorizing)
        XCTAssertFalse(state.canDismiss)
        XCTAssertFalse(state.beginAuthorization())

        state = .authorize
        XCTAssertTrue(state.canDismiss)
        XCTAssertTrue(state.beginAuthorization())
        state = .success
        XCTAssertTrue(state.canDismiss)
        XCTAssertTrue(PubkyAuthApprovalSheet.ApprovalState.watchOnlyConsent.canDismiss)
    }

    @MainActor
    func testReplacingAndReopeningSheetCannotStartConcurrentCompanionApproval() async throws {
        let suiteName = "PubkyAuthApprovalSheetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstAuthUrl = approvalTestAuthUrl()
        let secondAuthUrl = approvalTestAuthUrl(secret: "f3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s")
        let firstRequest = try PubkyAuthRequest.parse(url: firstAuthUrl)
        let secondRequest = try PubkyAuthRequest.parse(url: secondAuthUrl)
        let node = ApprovalFakeWatchOnlyAccountNode()
        let manager = Bitkit.WatchOnlyAccountManager(defaults: defaults, node: node)
        let companionApprovalGate = ApprovalCompanionGate()
        let firstApproval = Task { @MainActor in
            try await PubkyService.approveAuthRequest(
                request: firstRequest,
                authUrl: firstAuthUrl,
                accountName: "First account",
                secretKeyHex: "secret",
                accountManager: manager,
                companionApproval: { _, _, _, _, _ in await companionApprovalGate.approve() }
            )
        }
        try await companionApprovalGate.waitUntilFirstApprovalStarts()

        for (request, authUrl) in [(secondRequest, secondAuthUrl), (firstRequest, firstAuthUrl)] {
            do {
                try await PubkyService.approveAuthRequest(
                    request: request,
                    authUrl: authUrl,
                    accountName: "Replacement account",
                    secretKeyHex: "secret",
                    accountManager: manager,
                    companionApproval: { _, _, _, _, _ in XCTFail("Concurrent companion approval must not start") }
                )
                XCTFail("Expected concurrent authorization to be rejected")
            } catch {
                XCTAssertEqual(error as? Bitkit.WatchOnlyAccountError, .authorizationInProgress)
            }
        }

        let companionApprovalCount = await companionApprovalGate.approvalCount
        XCTAssertEqual(companionApprovalCount, 1)
        XCTAssertEqual(node.trackingChanges, [true])
        XCTAssertEqual(manager.accounts.map(\.setupState), [.authorizing, .pendingDelivery])

        await companionApprovalGate.releaseFirstApproval()
        try await firstApproval.value
        try await PubkyService.approveAuthRequest(
            request: secondRequest,
            authUrl: secondAuthUrl,
            accountName: "Second account",
            secretKeyHex: "secret",
            accountManager: manager,
            companionApproval: { _, _, _, _, _ in }
        )

        XCTAssertEqual(manager.accounts.map(\.setupState), [.active, .active])
        XCTAssertEqual(node.trackingChanges, [true, true])
    }

    @MainActor
    func testNormalAuthorizationFailureAfterCompanionDeliveryKeepsAccountTracked() async throws {
        let suiteName = "PubkyAuthApprovalSheetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let authUrl = approvalTestAuthUrl()
        let request = try PubkyAuthRequest.parse(url: authUrl)
        let node = ApprovalFakeWatchOnlyAccountNode()
        let manager = Bitkit.WatchOnlyAccountManager(defaults: defaults, node: node)

        await XCTAssertThrowsErrorAsync {
            try await PubkyService.approveAuthRequest(
                request: request,
                authUrl: authUrl,
                accountName: "Creator store",
                secretKeyHex: "secret",
                accountManager: manager,
                companionApproval: { _, _, _, _, _ in
                    throw Paykit.PubkyAuthCompanionClaimApprovalError.AuthorizationFailure(reason: "normal auth failed")
                }
            )
        }

        XCTAssertEqual(manager.accounts.first?.setupState, .authorizing)
        XCTAssertEqual(manager.accounts.first?.isTrackingEnabled, true)
        XCTAssertEqual(node.trackingChanges, [true])
    }

    @MainActor
    func testRetryFailureAfterCompanionDeliveryKeepsAccountTracked() async throws {
        let suiteName = "PubkyAuthApprovalSheetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let authUrl = approvalTestAuthUrl()
        let request = try PubkyAuthRequest.parse(url: authUrl)
        let node = ApprovalFakeWatchOnlyAccountNode()
        let manager = Bitkit.WatchOnlyAccountManager(defaults: defaults, node: node)

        await XCTAssertThrowsErrorAsync {
            try await PubkyService.approveAuthRequest(
                request: request,
                authUrl: authUrl,
                accountName: "Creator store",
                secretKeyHex: "secret",
                accountManager: manager,
                companionApproval: { _, _, _, _, _ in
                    throw Paykit.PubkyAuthCompanionClaimApprovalError.AuthorizationFailure(reason: "normal auth failed")
                }
            )
        }

        await XCTAssertThrowsErrorAsync {
            try await PubkyService.approveAuthRequest(
                request: request,
                authUrl: authUrl,
                accountName: "Creator store",
                secretKeyHex: "secret",
                accountManager: manager,
                companionApproval: { _, _, _, _, _ in throw ApprovalFakeError.deliveryFailed }
            )
        }

        XCTAssertEqual(manager.accounts.first?.setupState, .authorizing)
        XCTAssertEqual(manager.accounts.first?.isTrackingEnabled, true)
        XCTAssertEqual(node.trackingChanges, [true, true, true])
    }

    @MainActor
    func testRetryAfterRestartReusesAccountAndPayload() async throws {
        let suiteName = "PubkyAuthApprovalSheetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let authUrl = approvalTestAuthUrl()
        let request = try PubkyAuthRequest.parse(url: authUrl)
        let node = ApprovalFakeWatchOnlyAccountNode()
        let initialManager = Bitkit.WatchOnlyAccountManager(defaults: defaults, node: node)
        var deliveredPayloads: [Data] = []

        await XCTAssertThrowsErrorAsync {
            try await PubkyService.approveAuthRequest(
                request: request,
                authUrl: authUrl,
                accountName: "Creator store",
                secretKeyHex: "secret",
                accountManager: initialManager,
                companionApproval: { _, _, _, payload, _ in
                    try deliveredPayloads.append(XCTUnwrap(payload))
                    throw Paykit.PubkyAuthCompanionClaimApprovalError.AuthorizationFailure(reason: "normal auth failed")
                }
            )
        }

        let initialAccount = try XCTUnwrap(initialManager.accounts.first)
        XCTAssertEqual(initialAccount.setupState, .authorizing)
        XCTAssertTrue(initialAccount.isTrackingEnabled)

        let restartedManager = Bitkit.WatchOnlyAccountManager(defaults: defaults, node: node)
        try await PubkyService.approveAuthRequest(
            request: request,
            authUrl: authUrl,
            accountName: "Creator store",
            secretKeyHex: "secret",
            accountManager: restartedManager,
            companionApproval: { _, _, _, payload, _ in try deliveredPayloads.append(XCTUnwrap(payload)) }
        )

        let activeAccount = try XCTUnwrap(restartedManager.accounts.first)
        XCTAssertEqual(deliveredPayloads.count, 2)
        XCTAssertEqual(deliveredPayloads.first, deliveredPayloads.last)
        XCTAssertEqual(activeAccount.id, initialAccount.id)
        XCTAssertEqual(activeAccount.accountIndex, initialAccount.accountIndex)
        XCTAssertEqual(activeAccount.xpub, initialAccount.xpub)
        XCTAssertEqual(activeAccount.setupState, .active)
        XCTAssertTrue(activeAccount.isTrackingEnabled)
        XCTAssertEqual(node.trackingChanges, [true, true])
    }

    @MainActor
    func testTrackingPreparationFailureUnloadsAccountBeforeApproval() async throws {
        let suiteName = "PubkyAuthApprovalSheetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let authUrl = approvalTestAuthUrl()
        let request = try PubkyAuthRequest.parse(url: authUrl)
        let node = ApprovalFakeWatchOnlyAccountNode()
        node.failNextTrackingPreparation = true
        let manager = Bitkit.WatchOnlyAccountManager(defaults: defaults, node: node)
        var companionApprovalCount = 0

        await XCTAssertThrowsErrorAsync {
            try await PubkyService.approveAuthRequest(
                request: request,
                authUrl: authUrl,
                accountName: "Creator store",
                secretKeyHex: "secret",
                accountManager: manager,
                companionApproval: { _, _, _, _, _ in companionApprovalCount += 1 }
            )
        }

        XCTAssertEqual(companionApprovalCount, 0)
        XCTAssertEqual(manager.accounts.first?.setupState, .pendingDelivery)
        XCTAssertEqual(manager.accounts.first?.isTrackingEnabled, false)
        XCTAssertEqual(node.trackingChanges, [true, false])
    }

    @MainActor
    func testCancellationDuringCompanionDeliveryStillUnloadsAccount() async throws {
        let suiteName = "PubkyAuthApprovalSheetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let authUrl = approvalTestAuthUrl()
        let request = try PubkyAuthRequest.parse(url: authUrl)
        let node = ApprovalFakeWatchOnlyAccountNode()
        node.checkCancellationWhenDisabling = true
        let manager = Bitkit.WatchOnlyAccountManager(defaults: defaults, node: node)
        let companionApprovalGate = ApprovalCompanionGate()

        let approval = Task { @MainActor in
            try await PubkyService.approveAuthRequest(
                request: request,
                authUrl: authUrl,
                accountName: "Creator store",
                secretKeyHex: "secret",
                accountManager: manager,
                companionApproval: { _, _, _, _, _ in
                    await companionApprovalGate.approve()
                    try Task.checkCancellation()
                }
            )
        }
        try await companionApprovalGate.waitUntilFirstApprovalStarts()
        approval.cancel()
        await companionApprovalGate.releaseFirstApproval()

        do {
            try await approval.value
            XCTFail("Expected companion approval cancellation")
        } catch is CancellationError {}

        XCTAssertEqual(manager.accounts.first?.setupState, .pendingDelivery)
        XCTAssertEqual(manager.accounts.first?.isTrackingEnabled, false)
        XCTAssertEqual(node.trackingChanges, [true, false])
    }
}

private enum ApprovalFakeError: Error {
    case deliveryFailed
    case timedOut
    case trackingPreparationFailed
}

private actor ApprovalCompanionGate {
    private var count = 0
    private var firstApprovalContinuation: CheckedContinuation<Void, Never>?
    private var hasStartedFirstApproval = false

    var approvalCount: Int {
        count
    }

    func approve() async {
        count += 1
        guard count == 1 else { return }

        hasStartedFirstApproval = true

        await withCheckedContinuation { continuation in
            firstApprovalContinuation = continuation
        }
    }

    func waitUntilFirstApprovalStarts(timeout: Duration = .seconds(2)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !hasStartedFirstApproval {
            guard clock.now < deadline else { throw ApprovalFakeError.timedOut }
            await Task.yield()
        }
    }

    func releaseFirstApproval() {
        firstApprovalContinuation?.resume()
        firstApprovalContinuation = nil
    }
}

private final class ApprovalFakeWatchOnlyAccountNode: Bitkit.WatchOnlyAccountNodeHandling {
    var currentWalletIndex = 0
    var failNextTrackingPreparation = false
    var checkCancellationWhenDisabling = false
    private(set) var trackingChanges: [Bool] = []

    func exportWatchOnlyAccountXpub(accountIndex _: UInt32, addressType _: LDKNode.AddressType) async throws -> String {
        approvalTestXpub
    }

    func setWatchOnlyAccountTracking(
        accountIndex _: UInt32,
        addressType _: LDKNode.AddressType,
        xpub _: String,
        enabled: Bool
    ) async throws {
        if !enabled, checkCancellationWhenDisabling {
            try Task.checkCancellation()
        }
        trackingChanges.append(enabled)
        if enabled, failNextTrackingPreparation {
            failNextTrackingPreparation = false
            throw ApprovalFakeError.trackingPreparationFailed
        }
    }

    func reconcileWatchOnlyAccountTracking(
        records _: [Bitkit.WatchOnlyAccountRecord],
        managedRecords _: [Bitkit.WatchOnlyAccountRecord]
    ) async throws {}
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
