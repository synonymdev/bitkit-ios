@testable import Bitkit
import SwiftUI
import XCTest

@MainActor
final class ConnectionRecoveryServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var data: Data?
    private var currentOwner = ConnectionRecoveryService.Owner(walletIndex: 0, network: "regtest", binding: "original")
    private var service: ConnectionRecoveryService!

    override func setUp() async throws {
        suite = "ConnectionRecoveryTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
        data = nil
        currentOwner = .init(walletIndex: 0, network: "regtest", binding: "original")
        service = makeService()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        service = nil
        defaults = nil
    }

    func testStorageFaultSelectorRejectsOnlyItsExactAllowedBoundary() throws {
        for selected in ConnectionRecoveryTestFault.allowed {
            for point in ConnectionRecoveryTestFault.allowed {
                if selected == point {
                    XCTAssertThrowsError(try ConnectionRecoveryTestFault.check(point, selected: selected))
                } else {
                    XCTAssertNoThrow(try ConnectionRecoveryTestFault.check(point, selected: selected))
                }
            }
            XCTAssertNoThrow(try ConnectionRecoveryTestFault.check("bip39_mnemonic_0:delete", selected: selected))
            XCTAssertNoThrow(try ConnectionRecoveryTestFault.check("paykit_session:write", selected: selected))
        }
        XCTAssertNoThrow(try ConnectionRecoveryTestFault.check("connection_recovery:write", selected: nil))
        XCTAssertNoThrow(try ConnectionRecoveryTestFault.check("connection_recovery:write", selected: "*"))
    }

    private func makeService() -> ConnectionRecoveryService {
        ConnectionRecoveryService(owner: { self.currentOwner }, load: { self.data },
                                  store: { self.data = $0 }, clear: { self.data = nil }, defaults: defaults)
    }

    private var server: ElectrumServer {
        ElectrumServer(host: "localhost", port: 50001, protocolType: .tcp)
    }

    func testRestrictedEditorRendersWithLocalCorrectionOnCompactDisplay() async throws {
        try await service.save(editor: service.editor(), electrum: server)
        let editor = try service.editor()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = .dark
        let appeared = expectation(description: "Editor appears in the test window")
        let host = UIHostingController(rootView: WalletConnectionRecoveryView(editor: editor, onBack: {}, onRetry: {}, recovery: service)
            .onAppear { appeared.fulfill() })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        await fulfillment(of: [appeared], timeout: 2)
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()
        let size = host.sizeThatFits(in: window.bounds.size)
        XCTAssertGreaterThan(size.width, 300)
        XCTAssertGreaterThan(size.height, 500)
        XCTAssertLessThanOrEqual(size.width, window.bounds.width)
        XCTAssertLessThanOrEqual(size.height, window.bounds.height)
        var didDraw = false
        let rendered = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            didDraw = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(didDraw)
        let pixels = try XCTUnwrap(rendered.cgImage?.dataProvider?.data) as Data
        XCTAssertGreaterThan(Set(pixels).count, 8, "An empty black attachment is not rendered editor evidence")
        let attachment = XCTAttachment(image: rendered)
        attachment.name = "Restricted connection editor with synthetic local settings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEditorPresentedDuringStartupRemainsUsableAfterFailure() async throws {
        let editor = try service.editor()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let entered = expectation(description: "Startup is awaiting its native result")
        var release: CheckedContinuation<Void, Never>?
        let startup = Task {
            try await service.perform {
                await withCheckedContinuation { release = $0; entered.fulfill() }
                throw URLError(.cannotConnectToHost)
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        let appeared = expectation(description: "Editor is presented during startup")
        let host = UIHostingController(rootView: WalletConnectionRecoveryView(editor: editor, onBack: {}, onRetry: {}, recovery: service)
            .onAppear { appeared.fulfill() })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        await fulfillment(of: [appeared], timeout: 2)
        release?.resume()
        do { try await startup.value; XCTFail("Startup must retain its failure") } catch {}
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()
        func textFields(in view: UIView) -> [UITextField] {
            (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
        }
        let fields = textFields(in: host.view)
        XCTAssertEqual(fields.count, 2)
        XCTAssertTrue(fields.allSatisfy(\.isEnabled), "The original editor must become usable when startup fails")
    }

    func testIndependentSaveSurvivesReconstructionAndOldSettings() async throws {
        try await service.save(editor: service.editor(), electrum: server)
        let saved = try XCTUnwrap(data)
        let restored = makeService()
        try await restored.perform {
            let settings = try restored.mergeRestoredSettings(["electrumServer": "ssl://old:50002", "hideBalance": true])
            XCTAssertEqual(settings["electrumServer"] as? String, self.server.fullUrl)
            XCTAssertEqual(settings["hideBalance"] as? Bool, true)
            self.defaults.removeObject(forKey: "electrumServer")
            XCTAssertNotNil(try restored.replay())
            XCTAssertEqual(ElectrumConfigService(defaults: self.defaults).getCurrentServer(), self.server)
        }
        XCTAssertEqual(data, saved)
        try await restored.save(editor: restored.editor(), rgs: "")
        XCTAssertEqual(try JSONDecoder().decode(ConnectionRecoveryService.Record.self, from: XCTUnwrap(data)).rgs, "")
        XCTAssertEqual(ElectrumConfigService(defaults: defaults).getCurrentServer(), server)
    }

    func testFailedProbeDoesNotOverwriteAcknowledgedCorrection() async throws {
        try await service.save(editor: service.editor(), electrum: server)
        let saved = data
        do {
            try await service.save(editor: service.editor(), rgs: "https://invalid.example") {
                throw URLError(.cannotConnectToHost)
            }
            XCTFail("Failed probe must be reported")
        } catch {}
        XCTAssertEqual(data, saved)
        XCTAssertNil(defaults.string(forKey: "rapidGossipSyncUrl"))
    }

    func testMarkerWriteFailureDoesNotChangePreferences() async throws {
        let failing = ConnectionRecoveryService(owner: { self.currentOwner }, load: { nil },
                                                store: { _ in throw CocoaError(.fileWriteNoPermission) }, clear: {}, defaults: defaults)
        do {
            try await failing.save(editor: failing.editor(), electrum: server)
            XCTFail("Unacknowledged record must block settings mutation")
        } catch {}
        XCTAssertNil(defaults.data(forKey: "electrumServer"))
    }

    func testMissingOptionalSettingsCannotConsumeRequiredMarkerWhenReplayFails() async throws {
        var marker: Data? = Data("complete-wallet".utf8)
        let gate = WalletBackupRestoreGate(load: { marker }, store: { marker = $0 }, clear: { marker = nil })
        data = Data("unreadable-connection-record".utf8)
        do {
            _ = try await service.restoreRequired(gate: gate) { _ in true }
            XCTFail("Mandatory replay must fail outside optional SETTINGS handling")
        } catch {}
        XCTAssertEqual(marker, Data("complete-wallet".utf8))
        XCTAssertEqual(data, Data("unreadable-connection-record".utf8))
    }

    func testFreshRestoreArmsMarkerBeforeOwnerOrCorrectionReadFailure() async throws {
        for failOwner in [true, false] {
            var marker: Data?
            let gate = WalletBackupRestoreGate(load: { marker }, store: { marker = $0 }, clear: { marker = nil })
            let unavailable = ConnectionRecoveryService(owner: {
                if failOwner {
                    throw CocoaError(.fileReadNoPermission)
                }
                return self.currentOwner
            }, load: { throw CocoaError(.fileReadNoPermission) }, store: { _ in }, clear: {}, defaults: defaults)
            do {
                _ = try await unavailable.restoreRequired(gate: gate) { _ in
                    XCTFail("Unavailable recovery state must prevent import")
                    return true
                }
                XCTFail("Read failure must propagate")
            } catch {}
            let recreatedGate = WalletBackupRestoreGate(load: { marker }, store: { marker = $0 }, clear: { marker = nil })
            XCTAssertTrue(try recreatedGate.hasPendingRestore())
            XCTAssertTrue(try WalletBackupRestoreGate.blocksWalletStart(isRestoreRunning: false,
                                                                        hasPendingRestore: recreatedGate.hasPendingRestore(),
                                                                        isRestoreCompletionStart: false))
        }
    }

    func testActualFullAndLegacyEntriesRetainTheirRequiredMarkersOnUnavailableCorrection() async throws {
        let originalWallet = try Keychain.load(key: .paykitPendingBackupRestore)
        let originalUsdt = try Keychain.load(key: .usdtPendingBackupRestore)
        defer {
            do {
                if let originalWallet {
                    try Keychain.upsert(key: .paykitPendingBackupRestore, data: originalWallet)
                } else {
                    try Keychain.delete(key: .paykitPendingBackupRestore)
                }
                if let originalUsdt {
                    try Keychain.upsert(key: .usdtPendingBackupRestore, data: originalUsdt)
                } else {
                    try Keychain.delete(key: .usdtPendingBackupRestore)
                }
            } catch { XCTFail("Could not restore test marker state: \(error)") }
        }
        let unavailable = ConnectionRecoveryService(owner: { self.currentOwner },
                                                    load: { throw CocoaError(.fileReadNoPermission) },
                                                    store: { _ in }, clear: {}, defaults: defaults)
        let backup = BackupService(defaults: defaults, connectionRecovery: unavailable)
        for path in ["full", "legacy", "retained-usdt"] {
            try Keychain.delete(key: .paykitPendingBackupRestore)
            try Keychain.delete(key: .usdtPendingBackupRestore)
            let retained = Data("retained-complete-legacy-wallet".utf8)
            if path == "retained-usdt" {
                try Keychain.upsert(key: .usdtPendingBackupRestore, data: retained)
            }
            do {
                if path == "legacy" {
                    try await backup.restoreUsdtRecoveryAfterLegacyMigration()
                } else {
                    try await backup.performFullRestoreFromLatestBackup()
                }
                XCTFail("Unavailable correction must stop restore before remote work")
            } catch {}
            if path == "full" {
                XCTAssertEqual(try Keychain.load(key: .paykitPendingBackupRestore), Data())
                XCTAssertNil(try Keychain.load(key: .usdtPendingBackupRestore))
            } else {
                XCTAssertNil(try Keychain.load(key: .paykitPendingBackupRestore))
                XCTAssertEqual(try Keychain.load(key: .usdtPendingBackupRestore), path == "legacy" ? Data() : retained)
            }
            XCTAssertTrue(BackupService(defaults: defaults, connectionRecovery: unavailable).hasPendingWalletRestore())
        }
    }

    func testFailedLocalPromotionRetainsDurableCorrectionForReplay() async throws {
        let denied = try XCTUnwrap(FailingConnectionPreferences(suiteName: suite))
        denied.rejectWrites = true
        let failing = ConnectionRecoveryService(owner: { self.currentOwner }, load: { self.data },
                                                store: { self.data = $0 }, clear: { self.data = nil }, defaults: denied)
        do {
            try await failing.save(editor: failing.editor(), electrum: server)
            XCTFail("Failed settings promotion must not report saved")
        } catch {}
        XCTAssertNotNil(data)
        denied.rejectWrites = false
        try await failing.perform { XCTAssertNotNil(try failing.replay()) }
        XCTAssertEqual(ElectrumConfigService(defaults: denied).getCurrentServer(), server)
    }

    func testStaleEditorAndOldSuccessfulRevisionCannotEraseLaterCorrection() async throws {
        let stale = try service.editor()
        try await service.save(editor: stale, electrum: server)
        let earlier = try service.editor().revision
        try await service.save(editor: service.editor(), rgs: "https://rgs.example")
        let latest = data
        do {
            try await service.save(editor: stale, rgs: "https://old.example")
            XCTFail("Stale confirmation must not replace a newer correction")
        } catch {}
        try await service.perform {
            try self.service.complete(revision: earlier, hasPendingRestore: false, isRunning: true)
        }
        XCTAssertEqual(data, latest)
    }

    func testCompletionRequiresNodeAndRestoreThenClearsOnlySameRevision() async throws {
        try await service.save(editor: service.editor(), electrum: server)
        try await service.perform {
            let revision = try self.service.replay()
            try self.service.complete(revision: revision, hasPendingRestore: true, isRunning: true)
            XCTAssertNotNil(self.data)
            try self.service.complete(revision: revision, hasPendingRestore: false, isRunning: false)
            XCTAssertNotNil(self.data)
            try self.service.complete(revision: revision, hasPendingRestore: false, isRunning: true)
        }
        XCTAssertNil(data)
        XCTAssertEqual(ElectrumConfigService(defaults: defaults).getCurrentServer(), server)
    }

    func testColdStartupRetainsRestrictedHostUntilCorrectionCompletes() async throws {
        XCTAssertFalse(service.requiresRestrictedStartup(hasPendingRestore: false))
        try await service.save(editor: service.editor(), electrum: server)
        let restarted = makeService()
        XCTAssertTrue(restarted.requiresRestrictedStartup(hasPendingRestore: false))
        try await restarted.perform {
            let revision = try restarted.replay()
            try restarted.complete(revision: revision, hasPendingRestore: false, isRunning: false)
        }
        XCTAssertTrue(makeService().requiresRestrictedStartup(hasPendingRestore: false))
        try await restarted.perform {
            let revision = try restarted.replay()
            try restarted.complete(revision: revision, hasPendingRestore: false, isRunning: true)
        }
        XCTAssertFalse(makeService().requiresRestrictedStartup(hasPendingRestore: false))
    }

    func testColdStartupUnavailableCorrectionFailsClosedWithoutReadingBeforeRequiredRestore() {
        var reads = 0
        let unavailable = ConnectionRecoveryService(owner: { self.currentOwner }, load: {
            reads += 1
            throw CocoaError(.fileReadNoPermission)
        }, store: { _ in }, clear: {}, defaults: defaults)
        XCTAssertTrue(unavailable.requiresRestrictedStartup(hasPendingRestore: true))
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(unavailable.requiresRestrictedStartup(hasPendingRestore: false))
        XCTAssertEqual(reads, 1)
        data = Data("unreadable correction".utf8)
        XCTAssertTrue(makeService().requiresRestrictedStartup(hasPendingRestore: false))
        data = nil
        XCTAssertFalse(makeService().requiresRestrictedStartup(hasPendingRestore: false))
    }

    func testQueuedInitializationCannotFinishAfterWipeFailureUntilCurrentStartupIsAcknowledged() async throws {
        try await service.save(editor: service.editor(), electrum: server)
        let lifecycle = service.lifecycleID
        var dismissed = false
        var callbackAfterRemoval = false
        let appeared = expectation(description: "Initialization appears before wipe")
        let callback = expectation(description: "Old callback executes after failed wipe")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        let startup = Task {
            try await service.perform {
                _ = try self.service.replay()
                window.rootViewController = UIHostingController(rootView: InitializingWalletView(
                    nodeLifecycleState: .constant(.running), initialPercentage: 98.75
                ) {
                    callbackAfterRemoval = window.rootViewController == nil
                    if self.service.canFinishInitialization(lifecycle: lifecycle, isRunning: true,
                                                            hasPendingRestore: false, didFail: false)
                    {
                        dismissed = true
                    }
                    callback.fulfill()
                }.onAppear { appeared.fulfill() })
                window.makeKeyAndVisible()
                try await Task.sleep(for: .seconds(10))
                XCTFail("Wipe must cancel and drain the old startup")
            }
        }
        await fulfillment(of: [appeared], timeout: 2)
        try await Task.sleep(for: .milliseconds(200))
        var lifecycleDuringWipe: UUID?
        do {
            try await AppReset.withConnectionRecoveryPaused(recovery: service) {
                lifecycleDuringWipe = self.service.lifecycleID
                window.rootViewController = nil
                throw AppError(message: "Controlled node stop failure", debugMessage: nil)
            }
            XCTFail("Controlled wipe must fail")
        } catch {}
        do {
            try await startup.value
            XCTFail("Old startup must be cancelled")
        } catch is CancellationError {} catch { XCTFail("Unexpected startup error: \(error)") }
        await fulfillment(of: [callback], timeout: 3)
        XCTAssertTrue(callbackAfterRemoval)
        XCTAssertFalse(dismissed)
        XCTAssertNotNil(data)
        let currentLifecycle = try XCTUnwrap(lifecycleDuringWipe)
        XCTAssertFalse(service.canFinishInitialization(lifecycle: currentLifecycle, isRunning: true,
                                                       hasPendingRestore: false, didFail: false))
        try await service.perform {
            let revision = try self.service.replay()
            try self.service.complete(revision: revision, hasPendingRestore: false, isRunning: true)
        }
        XCTAssertTrue(service.canFinishInitialization(lifecycle: currentLifecycle, isRunning: true,
                                                      hasPendingRestore: false, didFail: false))
        XCTAssertFalse(service.canFinishInitialization(lifecycle: lifecycle, isRunning: true,
                                                       hasPendingRestore: false, didFail: false))
    }

    func testQueuedInitializationCallbackCannotDismissFailedCorrectionCleanup() async throws {
        let recovery = ConnectionRecoveryService(owner: { self.currentOwner }, load: { self.data },
                                                 store: { self.data = $0 }, clear: { throw CocoaError(.fileWriteNoPermission) },
                                                 defaults: defaults)
        try await recovery.save(editor: recovery.editor(), electrum: server)
        var didFail = false
        var dismissed = false
        var callbackAfterRemoval = false
        let appeared = expectation(description: "Initialization view appears")
        let callback = expectation(description: "Queued initialization callback executes after removal")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        do {
            try await recovery.perform {
                let revision = try recovery.replay()
                window.rootViewController = UIHostingController(rootView: InitializingWalletView(
                    nodeLifecycleState: .constant(.running), initialPercentage: 98.75
                ) {
                    callbackAfterRemoval = window.rootViewController == nil
                    if recovery
                        .canFinishInitialization(lifecycle: recovery.lifecycleID, isRunning: true, hasPendingRestore: false, didFail: didFail)
                    {
                        dismissed = true
                    }
                    callback.fulfill()
                }.onAppear { appeared.fulfill() })
                window.makeKeyAndVisible()
                await self.fulfillment(of: [appeared], timeout: 2)
                // Let the real view enqueue its delayed completion before finalization fails.
                try await Task.sleep(for: .milliseconds(200))
                try recovery.complete(revision: revision, hasPendingRestore: false, isRunning: true)
            }
            XCTFail("Injected correction cleanup must fail")
        } catch {
            didFail = true
        }
        window.rootViewController = nil
        XCTAssertFalse(recovery.isBusy)
        await fulfillment(of: [callback], timeout: 3)
        XCTAssertTrue(callbackAfterRemoval)
        XCTAssertFalse(dismissed)
        XCTAssertNotNil(data)

        let wipe = try await recovery.beginWipe()
        XCTAssertFalse(recovery.canFinishInitialization(lifecycle: recovery.lifecycleID, isRunning: true, hasPendingRestore: false, didFail: false))
        recovery.endWipe(wipe)
    }

    func testActivitySyncFailureAfterAcknowledgedStartDoesNotReopenRecovery() async throws {
        try await service.save(editor: service.editor(), electrum: server)
        let lifecycle = service.lifecycleID
        var showingError = true
        var didSync = false
        try await service.perform {
            do {
                let revision = try self.service.replay()
                try self.service.complete(revision: revision, hasPendingRestore: false, isRunning: true) {
                    showingError = false
                }
                let sync: () async throws -> Void = {
                    didSync = true
                    throw CocoaError(.fileReadCorruptFile)
                }
                try await sync()
            } catch {
                XCTAssertTrue(self.service.canReportOperationFailure(), "The sync error still belongs to this operation")
                if self.service.canReportStartupFailure() {
                    showingError = true
                }
            }
        }
        XCTAssertTrue(didSync)
        XCTAssertFalse(showingError)
        XCTAssertNil(data)
        XCTAssertTrue(service.canFinishInitialization(lifecycle: lifecycle, isRunning: true,
                                                      hasPendingRestore: false, didFail: showingError))
    }

    func testStartupFailureRemainsReportableUntilRecoveryIsAcknowledged() async throws {
        try await service.save(editor: service.editor(), electrum: server)
        try await service.perform {
            let revision = try self.service.replay()
            XCTAssertTrue(self.service.canReportStartupFailure())
            try self.service.complete(revision: revision, hasPendingRestore: true, isRunning: true)
            XCTAssertTrue(self.service.canReportStartupFailure())
            try self.service.complete(revision: revision, hasPendingRestore: false, isRunning: false)
            XCTAssertTrue(self.service.canReportStartupFailure())
        }
        XCTAssertNotNil(data)
        XCTAssertFalse(service.canReportStartupFailure(), "A completed operation cannot report a late error")
    }

    func testAnotherStartDoesNotInheritEarlierSuccessfulRecovery() async throws {
        try await service.perform {
            try self.service.complete(revision: nil, hasPendingRestore: false, isRunning: true)
        }
        try await service.perform {
            XCTAssertTrue(self.service.canReportStartupFailure())
        }
    }

    func testAutomaticResumeClearsPriorErrorOnlyAfterAcknowledgedStartup() async throws {
        var showingError = true
        try await service.save(editor: service.editor(), electrum: server)
        try await service.perform {
            let revision = try self.service.replay()
            try self.service.complete(revision: revision, hasPendingRestore: false, isRunning: false) { showingError = false }
            XCTAssertTrue(showingError)
            try self.service.complete(revision: revision, hasPendingRestore: true, isRunning: true) { showingError = false }
            XCTAssertTrue(showingError)
        }
        let restarted = makeService()
        try await restarted.perform {
            let revision = try restarted.replay()
            try restarted.complete(revision: revision, hasPendingRestore: false, isRunning: true) { showingError = false }
        }
        XCTAssertFalse(showingError)
        XCTAssertNil(data)

        // A later automatic resume has no correction left, but must still retire its old error host.
        showingError = true
        try await restarted.perform {
            XCTAssertNil(try restarted.replay())
            try restarted.complete(revision: nil, hasPendingRestore: false, isRunning: true) { showingError = false }
        }
        XCTAssertFalse(showingError)

        showingError = true
        let failedCleanup = ConnectionRecoveryService(owner: { self.currentOwner }, load: { self.data },
                                                      store: { self.data = $0 }, clear: { throw CocoaError(.fileWriteNoPermission) },
                                                      defaults: defaults)
        try await failedCleanup.save(editor: failedCleanup.editor(), electrum: server)
        do {
            try await failedCleanup.perform {
                let revision = try failedCleanup.replay()
                try failedCleanup.complete(revision: revision, hasPendingRestore: false, isRunning: true) { showingError = false }
            }
            XCTFail("Failed correction cleanup must retain the error host")
        } catch {}
        XCTAssertTrue(showingError)
        XCTAssertNotNil(data)
    }

    func testWipeDrainsNonCancellableProbeAndRejectsSameSeedOldEditor() async throws {
        let editor = try service.editor()
        let entered = expectation(description: "Probe entered")
        var release: CheckedContinuation<Void, Never>?
        let save = Task {
            try await service.save(editor: editor, electrum: server) {
                await withCheckedContinuation { release = $0; entered.fulfill() }
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        var wipeReturned = false
        let wipe = Task { let id = try await service.beginWipe(); wipeReturned = true; return id }
        await Task.yield()
        XCTAssertFalse(wipeReturned)
        release?.resume()
        _ = await save.result
        let wipeID = try await wipe.value
        XCTAssertNil(data)
        XCTAssertNil(defaults.data(forKey: "electrumServer"))
        service.endWipe(wipeID)
        do {
            try await service.save(editor: editor, electrum: server)
            XCTFail("Same seed replacement must not revive an old editor")
        } catch {}
        XCTAssertFalse(service.isBusy)
        try await service.save(editor: service.editor(), electrum: server)
        XCTAssertNotNil(data)
    }

    func testIdentityReplacementDuringValidationCannotWrite() async throws {
        let editor = try service.editor()
        do {
            try await service.save(editor: editor, electrum: server) {
                self.currentOwner = .init(walletIndex: 0, network: "regtest", binding: "replacement")
            }
            XCTFail("Replacement must reject old work")
        } catch {}
        XCTAssertNil(data)
        XCTAssertNil(defaults.data(forKey: "electrumServer"))
    }

    func testCancelledCallerCannotCommitAfterSuspendedProbe() async throws {
        let editor = try service.editor()
        let entered = expectation(description: "Probe entered")
        var release: CheckedContinuation<Void, Never>?
        let save = Task {
            try await service.save(editor: editor, electrum: server) {
                await withCheckedContinuation { release = $0; entered.fulfill() }
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        save.cancel()
        release?.resume()
        _ = await save.result
        XCTAssertNil(data)
        XCTAssertFalse(service.isBusy)
    }

    func testEscapedOperationCannotReplayAfterItsScopeEnds() async throws {
        var escaped: Task<UUID?, Error>?
        var release: CheckedContinuation<Void, Never>?
        let entered = expectation(description: "Escaped task waiting")
        try await service.perform {
            escaped = Task {
                await withCheckedContinuation { release = $0; entered.fulfill() }
                return try self.service.replay()
            }
            await self.fulfillment(of: [entered], timeout: 2)
        }
        release?.resume()
        do {
            _ = try await escaped?.value
            XCTFail("Inherited scope must be revoked after return")
        } catch {}
    }

    func testSecondWipeCannotReleaseOriginalAdmission() async throws {
        let original = try await service.beginWipe()
        do {
            _ = try await service.beginWipe()
            XCTFail("Duplicate wipe must be rejected before registering cleanup")
        } catch ConnectionRecoveryService.AdmissionError.busy {} catch { XCTFail("Unexpected error: \(error)") }
        service.endWipe(UUID())
        do {
            try await service.perform {}
            XCTFail("Foreign cleanup must not reopen admission")
        } catch ConnectionRecoveryService.AdmissionError.busy {} catch { XCTFail("Unexpected error: \(error)") }
        service.endWipe(original)
        try await service.perform {}
    }

    func testAdmittedRetryFinishesAfterEditorDismissal() async throws {
        let entered = expectation(description: "Native stop is suspended")
        var release: CheckedContinuation<Void, Never>?
        var events: [String] = []
        let retry = Task {
            try await service.perform(cancelsWithCaller: false) {
                events.append("stop")
                await withCheckedContinuation { release = $0; entered.fulfill() }
                try self.service.checkCurrentOperation()
                events.append("restore")
                events.append("start")
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        retry.cancel()
        release?.resume()
        try await retry.value
        XCTAssertEqual(events, ["stop", "restore", "start"])
        XCTAssertFalse(service.isBusy)
    }

    func testDismissedRetryCanReportOwnerReadFailureWithoutReauthorizingWork() async {
        var ownerUnavailable = false
        let recovery = ConnectionRecoveryService(owner: {
            if ownerUnavailable {
                throw CocoaError(.fileReadNoPermission)
            }
            return self.currentOwner
        }, load: { nil }, store: { _ in }, clear: {}, defaults: defaults)
        let entered = expectation(description: "Restore is suspended")
        var release: CheckedContinuation<Void, Never>?
        var reportedFailure = false
        var started = false
        let retry = Task {
            try await recovery.perform(cancelsWithCaller: false) {
                _ = try recovery.replay()
                await withCheckedContinuation { release = $0; entered.fulfill() }
                do {
                    try recovery.checkCurrentOperation()
                    started = true
                } catch {
                    reportedFailure = recovery.canReportOperationFailure()
                }
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        retry.cancel()
        ownerUnavailable = true
        release?.resume()
        _ = await retry.result
        XCTAssertTrue(reportedFailure)
        XCTAssertFalse(started)
        XCTAssertFalse(recovery.canReportOperationFailure())
    }

    func testAppResetDrainPrecedesSdkWipeAndDuplicateCannotReopenSettings() async throws {
        let lock = PaykitSdkOperationLock()
        let recoveryEntered = expectation(description: "Recovery owns SDK")
        let wipeEntered = expectation(description: "Wipe owns SDK after drain")
        var releaseRecovery: CheckedContinuation<Void, Never>?
        var releaseWipe: CheckedContinuation<Void, Never>?
        var events: [String] = []
        let recovery = Task {
            try await service.perform(cancelsWithCaller: false) {
                defer { events.append("recovery drained") }
                try await lock.withLock {
                    events.append("recovery SDK")
                    await withCheckedContinuation { releaseRecovery = $0; recoveryEntered.fulfill() }
                }
            }
        }
        await fulfillment(of: [recoveryEntered], timeout: 2)
        let originalGeneration = service.lifecycleID
        let wipe = Task {
            try await AppReset.withConnectionRecoveryPaused(recovery: service) {
                try await lock.withWalletWipe {
                    events.append("wipe SDK")
                    await withCheckedContinuation { releaseWipe = $0; wipeEntered.fulfill() }
                }
            }
        }
        for _ in 0 ..< 100 where service.isCurrentLifecycle(originalGeneration) {
            await Task.yield()
        }
        XCTAssertFalse(service.isCurrentLifecycle(originalGeneration))
        XCTAssertEqual(events, ["recovery SDK"])
        releaseRecovery?.resume()
        await fulfillment(of: [wipeEntered], timeout: 2)
        do {
            try await AppReset.withConnectionRecoveryPaused(recovery: service) {
                XCTFail("A second wipe must not enter")
            }
            XCTFail("A second wipe must be rejected")
        } catch ConnectionRecoveryService.AdmissionError.busy {} catch { XCTFail("Unexpected error: \(error)") }
        let settings = SettingsViewModel.shared
        XCTAssertFalse(settings.isCurrentServerConnection(settings.serverConnectionGeneration))
        XCTAssertFalse(service.isCurrentLifecycle(service.lifecycleID))
        releaseWipe?.resume()
        _ = await recovery.result
        try await wipe.value
        XCTAssertEqual(events, ["recovery SDK", "recovery drained", "wipe SDK"])
        XCTAssertTrue(settings.isCurrentServerConnection(settings.serverConnectionGeneration))
        XCTAssertTrue(service.isCurrentLifecycle(service.lifecycleID))
    }
}

private final class FailingConnectionPreferences: UserDefaults {
    var rejectWrites = false
    override func set(_ value: Any?, forKey defaultName: String) {
        if !rejectWrites {
            super.set(value, forKey: defaultName)
        }
    }
}
