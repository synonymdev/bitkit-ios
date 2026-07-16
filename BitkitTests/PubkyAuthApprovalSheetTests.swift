@testable import Bitkit
import LDKNode
import Paykit
import XCTest

private let approvalTestXpub =
    "tpubDDWohsp5dx2iMJ9N7iHbgAEDhH4BJB9NWW1fEW3yA3AFNDREmpzteCXNqppMLUmKFY5q5e3" +
    "PXtS5CuqWCQbYcGhpPqYAgQSYdwknW9J6sQv"

final class PubkyAuthApprovalSheetTests: XCTestCase {
    func testAuthDisplayPublicKeyOmitsPubkyPrefix() {
        XCTAssertEqual(pubkyAuthDisplayPublicKey("pubky3rsd123456789w5xg"), "3rsd...w5xg")
        XCTAssertEqual(pubkyAuthDisplayPublicKey("3rsd123456789w5xg"), "3rsd...w5xg")
        XCTAssertEqual(pubkyAuthDisplayPublicKey(nil), "")
    }

    @MainActor
    func testWatchOnlyRequestStartsWithSeparateConsentBeforeAuthorization() throws {
        let authUrl = "pubkyauth://signin?caps=/pub/paykit/v0/bitkit/server/:rw&relay=https://httprelay.pubky.app/inbox/&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s&x-bitkit-claim=watch-only-account-v1"
        let request = try PubkyAuthRequest.parse(url: authUrl)
        var state = PubkyAuthApprovalSheet.initialState(for: request)

        XCTAssertEqual(state, .watchOnlyConsent)
        XCTAssertTrue(state.approveWatchOnlyConsent())
        XCTAssertEqual(state, .authorize)
        XCTAssertFalse(state.approveWatchOnlyConsent())
    }

    func testOrdinaryRequestStartsAtNormalAuthorization() throws {
        let authUrl = "pubkyauth://signin?caps=/pub/example/:rw&relay=https://httprelay.pubky.app/inbox/&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s"
        let request = try PubkyAuthRequest.parse(url: authUrl)

        XCTAssertEqual(PubkyAuthApprovalSheet.initialState(for: request), .authorize)
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

        let authUrl = "pubkyauth://signin?caps=/pub/paykit/v0/bitkit/server/:rw&relay=https://httprelay.pubky.app/inbox/&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s&x-bitkit-claim=watch-only-account-v1"
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
                ordinaryApproval: { _, _, _ in ordinaryApprovalCount += 1 },
                companionApproval: { _, _, _ in
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

        let authUrl = "pubkyauth://signin?caps=/pub/paykit/v0/bitkit/server/:rw&relay=https://httprelay.pubky.app/inbox/&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s&x-bitkit-claim=watch-only-account-v1"
        let request = try PubkyAuthRequest.parse(url: authUrl)
        let node = ApprovalFakeWatchOnlyAccountNode()
        let manager = Bitkit.WatchOnlyAccountManager(defaults: defaults, node: node)

        try await PubkyService.approveAuthRequest(
            request: request,
            authUrl: authUrl,
            accountName: "Creator store",
            secretKeyHex: "secret",
            accountManager: manager,
            companionApproval: { _, _, _ in }
        )

        XCTAssertEqual(manager.accounts.first?.setupState, .active)
        XCTAssertEqual(manager.accounts.first?.isTrackingEnabled, true)
        XCTAssertEqual(node.trackingChanges, [true])
    }

    @MainActor
    func testApprovalStateBeginsAuthorizationOnlyOnce() {
        var state = PubkyAuthApprovalSheet.ApprovalState.authorize

        XCTAssertTrue(state.beginAuthorization())
        XCTAssertEqual(state, .authorizing)
        XCTAssertFalse(state.beginAuthorization())
    }

    @MainActor
    func testReplacingAndReopeningSheetCannotStartConcurrentCompanionApproval() async throws {
        let suiteName = "PubkyAuthApprovalSheetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstAuthUrl = "pubkyauth://signin?caps=/pub/paykit/v0/bitkit/server/:rw&relay=https://httprelay.pubky.app/inbox/&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s&x-bitkit-claim=watch-only-account-v1"
        let secondAuthUrl = "pubkyauth://signin?caps=/pub/paykit/v0/bitkit/server/:rw&relay=https://httprelay.pubky.app/inbox/&secret=f3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s&x-bitkit-claim=watch-only-account-v1"
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
                companionApproval: { _, _, _ in await companionApprovalGate.approve() }
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
                    companionApproval: { _, _, _ in XCTFail("Concurrent companion approval must not start") }
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
            companionApproval: { _, _, _ in }
        )

        XCTAssertEqual(manager.accounts.map(\.setupState), [.active, .active])
        XCTAssertEqual(node.trackingChanges, [true, true])
    }

    @MainActor
    func testNormalAuthorizationFailureAfterCompanionDeliveryKeepsAccountTracked() async throws {
        let suiteName = "PubkyAuthApprovalSheetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let authUrl = "pubkyauth://signin?caps=/pub/paykit/v0/bitkit/server/:rw&relay=https://httprelay.pubky.app/inbox/&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s&x-bitkit-claim=watch-only-account-v1"
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
                companionApproval: { _, _, _ in
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

        let authUrl = "pubkyauth://signin?caps=/pub/paykit/v0/bitkit/server/:rw&relay=https://httprelay.pubky.app/inbox/&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s&x-bitkit-claim=watch-only-account-v1"
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
                companionApproval: { _, _, _ in
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
                companionApproval: { _, _, _ in throw ApprovalFakeError.deliveryFailed }
            )
        }

        XCTAssertEqual(manager.accounts.first?.setupState, .authorizing)
        XCTAssertEqual(manager.accounts.first?.isTrackingEnabled, true)
        XCTAssertEqual(node.trackingChanges, [true, true, true])
    }

    @MainActor
    func testTrackingPreparationFailureUnloadsAccountBeforeApproval() async throws {
        let suiteName = "PubkyAuthApprovalSheetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let authUrl = "pubkyauth://signin?caps=/pub/paykit/v0/bitkit/server/:rw&relay=https://httprelay.pubky.app/inbox/&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s&x-bitkit-claim=watch-only-account-v1"
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
                companionApproval: { _, _, _ in companionApprovalCount += 1 }
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

        let authUrl = "pubkyauth://signin?caps=/pub/paykit/v0/bitkit/server/:rw&relay=https://httprelay.pubky.app/inbox/&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s&x-bitkit-claim=watch-only-account-v1"
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
                companionApproval: { _, _, _ in
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
