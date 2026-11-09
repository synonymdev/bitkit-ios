@testable import Bitkit
import XCTest

/// Runs the wipe's node and storage steps for real and leaves out the ones that reset the host app's own state (its
/// preferences, services and Paykit endpoints), which a test must never touch.
@MainActor
private final class NodeWipeExecutor: WipeStepExecutor {
    let wallet: WalletViewModel
    let store: FakePinLockoutStore
    private(set) var finishedReasons: [WipeReason?] = []

    init(wallet: WalletViewModel, store: FakePinLockoutStore) {
        self.wallet = wallet
        self.store = store
    }

    func withWipeScope(_ steps: () async throws -> Void) async throws {
        wallet.closeStartAdmissionForWipe()
        try await steps()
    }

    func run(_ step: WipeStep) async throws {
        switch step {
        case .stopNode:
            try await wallet.stopForWipe()
        case .wipeLightningStorage:
            try await wallet.wipe()
        case .wipeKeychain:
            try AppReset.wipeKeychain()
        case .commit:
            store.intent = nil
        default:
            break
        }
    }

    func finish(reason: WipeReason?) {
        finishedReasons.append(reason)
    }
}

/// A node built against a reachable VSS whose `start()` then fails to reach Electrum is left built but not running, and
/// ldk-node's `stop()` refuses it with `NotRunning`. The wipe must still release it and delete its storage.
@MainActor
final class WalletWipeAfterFailedStartIntegrationTests: XCTestCase {
    private let walletIndex = 0
    private let unreachableElectrumServerUrl = "tcp://127.0.0.1:1"
    private let lightning = Bitkit.LightningService.shared

    override func setUp() async throws {
        try await super.setUp()
        try skipIfNotRegtest()
        // Creating the wallet and wiping it write the address types and cached balances to the host app's preferences.
        snapshotAppDefaultsDomain()
        // A start would otherwise run the one-time network graph cleanup against VSS.
        UserDefaults.standard.set(true, forKey: "legacyNetworkGraphCleanupDone")
        try Keychain.wipeEntireKeychain()
    }

    override func tearDown() async throws {
        try? await lightning.stop()
        try? await lightning.wipeStorage(walletIndex: walletIndex)
        try Keychain.wipeEntireKeychain()
        try await super.tearDown()
    }

    private func skipIfNotRegtest() throws {
        guard Env.network == .regtest else {
            throw XCTSkip("Wallet wipe integration tests require regtest")
        }
    }

    func testWipeCompletesForANodeWhoseStartFailed() async throws {
        _ = try StartupHandler.createNewWallet(bip39Passphrase: nil, walletIndex: walletIndex)
        // The wallet's own start would set up the node with the configured Electrum server; built here first, it keeps
        // the unreachable one.
        try await lightning.setup(walletIndex: walletIndex, electrumServerUrl: unreachableElectrumServerUrl)
        let wallet = WalletViewModel()

        await assertThrowsAsync { try await wallet.start(walletIndex: self.walletIndex) }

        guard case .errorStarting = wallet.nodeLifecycleState else {
            return XCTFail("Expected errorStarting, got \(wallet.nodeLifecycleState)")
        }
        XCTAssertTrue(lightning.hasNode, "A failed start leaves the node built")

        let store = FakePinLockoutStore()
        let executor = NodeWipeExecutor(wallet: wallet, store: store)
        let coordinator = WipeCoordinator(store: store, makeExecutor: { executor }, retryDelays: [])
        try coordinator.begin(.userReset)
        await coordinator.waitForCurrentAttempt()

        XCTAssertEqual(coordinator.gate, .none)
        XCTAssertEqual(executor.finishedReasons, [.userReset])
        XCTAssertNil(store.intent)
        XCTAssertFalse(lightning.hasNode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Env.ldkStorage(walletIndex: walletIndex).path))
        XCTAssertNil(try Keychain.loadString(key: .bip39Mnemonic(index: walletIndex)))
    }
}
