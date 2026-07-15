import Base58Swift
@testable import Bitkit
import LDKNode
import Paykit
import XCTest

final class PubkyAuthApprovalSheetTests: XCTestCase {
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
            try await approvePubkyAuthRequest(
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

        try await approvePubkyAuthRequest(
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
    func testDuplicateConfirmationRunsOneCompanionApprovalLifecycle() async throws {
        let suiteName = "PubkyAuthApprovalSheetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let authUrl = "pubkyauth://signin?caps=/pub/paykit/v0/bitkit/server/:rw&relay=https://httprelay.pubky.app/inbox/&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s&x-bitkit-claim=watch-only-account-v1"
        let request = try PubkyAuthRequest.parse(url: authUrl)
        let node = ApprovalFakeWatchOnlyAccountNode()
        let manager = Bitkit.WatchOnlyAccountManager(defaults: defaults, node: node)
        let companionApprovalGate = ApprovalCompanionGate()
        let harness = ApprovalSingleFlightHarness(
            request: request,
            authUrl: authUrl,
            manager: manager,
            companionApprovalGate: companionApprovalGate
        )

        let firstConfirmation = Task { @MainActor in
            try await harness.confirm()
        }
        await companionApprovalGate.waitUntilFirstApprovalStarts()

        do {
            try await harness.confirm()
        } catch {
            await companionApprovalGate.releaseFirstApproval()
            _ = try? await firstConfirmation.value
            throw error
        }

        let companionApprovalCount = await companionApprovalGate.approvalCount
        XCTAssertEqual(companionApprovalCount, 1)
        XCTAssertEqual(node.trackingChanges, [true])

        await companionApprovalGate.releaseFirstApproval()
        try await firstConfirmation.value

        XCTAssertEqual(manager.accounts.count, 1)
        XCTAssertEqual(manager.accounts.first?.setupState, .active)
        XCTAssertEqual(node.trackingChanges, [true])
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
            try await approvePubkyAuthRequest(
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
            try await approvePubkyAuthRequest(
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
}

private enum ApprovalFakeError: Error {
    case deliveryFailed
    case trackingPreparationFailed
}

@MainActor
private final class ApprovalSingleFlightHarness {
    private var state: PubkyAuthApprovalSheet.ApprovalState = .authorize
    private let request: Bitkit.PubkyAuthRequest
    private let authUrl: String
    private let manager: Bitkit.WatchOnlyAccountManager
    private let companionApprovalGate: ApprovalCompanionGate

    init(
        request: Bitkit.PubkyAuthRequest,
        authUrl: String,
        manager: Bitkit.WatchOnlyAccountManager,
        companionApprovalGate: ApprovalCompanionGate
    ) {
        self.request = request
        self.authUrl = authUrl
        self.manager = manager
        self.companionApprovalGate = companionApprovalGate
    }

    func confirm() async throws {
        guard state.beginAuthorization() else { return }

        do {
            try await approvePubkyAuthRequest(
                request: request,
                authUrl: authUrl,
                accountName: "Creator store",
                secretKeyHex: "secret",
                accountManager: manager,
                companionApproval: { [companionApprovalGate] _, _, _ in
                    await companionApprovalGate.approve()
                }
            )
            state = .success
        } catch {
            state = .authorize
            throw error
        }
    }
}

private actor ApprovalCompanionGate {
    private var count = 0
    private var firstApprovalContinuation: CheckedContinuation<Void, Never>?
    private var firstApprovalStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasStartedFirstApproval = false

    var approvalCount: Int {
        count
    }

    func approve() async {
        count += 1
        guard count == 1 else { return }

        hasStartedFirstApproval = true
        let waiters = firstApprovalStartWaiters
        firstApprovalStartWaiters.removeAll()
        waiters.forEach { $0.resume() }

        await withCheckedContinuation { continuation in
            firstApprovalContinuation = continuation
        }
    }

    func waitUntilFirstApprovalStarts() async {
        guard !hasStartedFirstApproval else { return }

        await withCheckedContinuation { continuation in
            firstApprovalStartWaiters.append(continuation)
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
    private(set) var trackingChanges: [Bool] = []

    func exportWatchOnlyAccountXpub(accountIndex _: UInt32, addressType _: LDKNode.AddressType) async throws -> String {
        base58CheckEncode(Data((0 ..< Bitkit.WatchOnlyAccountClaimCodec.serializedXpubLength).map { UInt8($0 + 1) }))
    }

    func setWatchOnlyAccountTracking(
        accountIndex _: UInt32,
        addressType _: LDKNode.AddressType,
        xpub _: String,
        enabled: Bool
    ) async throws {
        trackingChanges.append(enabled)
        if enabled, failNextTrackingPreparation {
            failNextTrackingPreparation = false
            throw ApprovalFakeError.trackingPreparationFailed
        }
    }

    private func base58CheckEncode(_ payload: Data) -> String {
        Base58.base58CheckEncode([UInt8](payload))
    }
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
