@testable import Bitkit
import Combine
import XCTest

@MainActor
final class ServerConnectionResetTests: XCTestCase {
    private let settings = SettingsViewModel.shared

    override func setUp() {
        super.setUp()
        snapshotAppDefaultsDomain()
        settings.resetToDefaults()
        addTeardownBlock { @MainActor in
            self.settings.endServerSettingsWipe()
            self.settings.resetToDefaults()
        }
    }

    func testRgsEndpointSuccessAfterResetCannotSaveOrRestart() async {
        await verifyLateRgsEndpoint(isReachable: true)
    }

    func testRgsEndpointFailureAfterResetCannotChangeNewLoadingState() async {
        await verifyLateRgsEndpoint(isReachable: false)
    }

    private func verifyLateRgsEndpoint(isReachable: Bool) async {
        let endpoint = ConnectionGate<Bool>()
        settings.rgsServerUrl = "https://old.example.com/snapshot"
        var restartCount = 0
        let connection = Task {
            await settings.connectToRgsServer(checkEndpoint: { _ in await endpoint.wait() }) { _, _ in
                restartCount += 1
            }
        }
        await fulfillment(of: [endpoint.started], timeout: 3)

        clearServerPreferencesAndReset()
        settings.rgsIsLoading = true
        endpoint.resume(isReachable)
        let result = await connection.value

        XCTAssertNil(result, "A stale attempt must not produce a success or error toast")
        XCTAssertEqual(restartCount, 0)
        XCTAssertNil(UserDefaults.standard.string(forKey: "rapidGossipSyncUrl"))
        XCTAssertEqual(settings.rgsServerUrl, settings.rgsConfigService.getDefaultServerUrl())
        XCTAssertTrue(settings.rgsIsLoading, "The old completion must not clear a new attempt's loading flag")
    }

    func testRgsRestartFailureAfterResetIsIgnored() async {
        let restart = ConnectionGate<Void>()
        settings.rgsServerUrl = "https://old.example.com/snapshot"
        let connection = Task {
            await settings.connectToRgsServer(checkEndpoint: { _ in true }) { _, _ in
                await restart.wait()
                throw TestError.restartFailed
            }
        }
        await fulfillment(of: [restart.started], timeout: 3)
        clearServerPreferencesAndReset()
        settings.rgsIsLoading = true
        restart.resume(())

        let result = await connection.value
        XCTAssertNil(result)
        XCTAssertNil(UserDefaults.standard.string(forKey: "rapidGossipSyncUrl"))
        XCTAssertTrue(settings.rgsIsLoading)
    }

    func testElectrumRestartSuccessAfterResetCannotSave() async {
        await verifyLateElectrumRestart(fails: false)
    }

    func testElectrumRestartFailureAfterResetCannotOverwriteNewForm() async {
        await verifyLateElectrumRestart(fails: true)
    }

    private func verifyLateElectrumRestart(fails: Bool) async {
        let restart = ConnectionGate<Void>()
        setOldElectrumForm()
        var waitCount = 0
        let connection = Task {
            await settings.connectToElectrumServer(restartNode: { _, _ in
                await restart.wait()
                if fails {
                    throw TestError.restartFailed
                }
            }, waitForConnection: {
                waitCount += 1
            }, isNodeRunning: { true })
        }
        await fulfillment(of: [restart.started], timeout: 3)
        clearServerPreferencesAndReset()
        settings.electrumHost = "new.example.com"
        settings.electrumIsLoading = true
        restart.resume(())

        let result = await connection.value
        XCTAssertNil(result)
        XCTAssertEqual(waitCount, 0)
        XCTAssertNil(settings.electrumConfigService.getStoredServer())
        XCTAssertEqual(settings.electrumHost, "new.example.com")
        XCTAssertFalse(settings.electrumIsConnected)
        XCTAssertTrue(settings.electrumIsLoading)
    }

    func testElectrumConnectionWaitAfterResetCannotSave() async {
        let wait = ConnectionGate<Void>()
        setOldElectrumForm()
        let connection = Task {
            await settings.connectToElectrumServer(restartNode: { _, _ in }, waitForConnection: {
                await wait.wait()
            }, isNodeRunning: { true })
        }
        await fulfillment(of: [wait.started], timeout: 3)
        clearServerPreferencesAndReset()
        wait.resume(())

        let result = await connection.value
        XCTAssertNil(result)
        XCTAssertNil(settings.electrumConfigService.getStoredServer())
        XCTAssertEqual(settings.electrumCurrentServer, settings.electrumConfigService.getDefaultServer())
        XCTAssertFalse(settings.electrumIsConnected)
        XCTAssertFalse(settings.electrumIsLoading)
    }

    func testWipeDrainsRestartBlocksNewAttemptsAndAllowsConnectionsAfterward() async {
        let restart = ConnectionGate<Void>()
        let electrumRestart = ConnectionGate<Void>()
        settings.rgsServerUrl = "https://old.example.com/snapshot"
        let oldGeneration = settings.serverConnectionGeneration
        let connection = Task {
            await settings.connectToRgsServer(checkEndpoint: { _ in true }) { _, _ in
                await restart.wait()
            }
        }
        setOldElectrumForm()
        let electrumConnection = Task {
            await settings.connectToElectrumServer(restartNode: { _, _ in
                await electrumRestart.wait()
            }, waitForConnection: {}, isNodeRunning: { true })
        }
        await fulfillment(of: [restart.started, electrumRestart.started], timeout: 3)

        let invalidated = expectation(description: "Wipe invalidates the pending connection")
        let observation = settings.$rgsIsLoading.dropFirst().filter { !$0 }.first().sink { _ in invalidated.fulfill() }
        defer { observation.cancel() }
        var wipeFinished = false
        let wipe = Task {
            await settings.beginServerSettingsWipe()
            wipeFinished = true
        }
        await fulfillment(of: [invalidated], timeout: 3)
        XCTAssertFalse(wipeFinished, "Node storage must not be wiped while a restart is still executing")
        XCTAssertFalse(settings.isCurrentServerConnection(oldGeneration))

        let blockedRgs = await settings.connectToRgsServer(checkEndpoint: { _ in
            XCTFail("No endpoint check should start during wipe")
            return true
        }, restartNode: { _, _ in XCTFail("No RGS restart should start during wipe") })
        let blockedElectrum = await settings.connectToElectrumServer(restartNode: { _, _ in
            XCTFail("No Electrum restart should start during wipe")
        }, waitForConnection: {}, isNodeRunning: { true })
        XCTAssertNil(blockedRgs)
        XCTAssertNil(blockedElectrum)

        restart.resume(())
        let staleResult = await connection.value
        XCTAssertFalse(wipeFinished, "Wipe must drain Electrum as well as RGS")
        electrumRestart.resume(())
        await wipe.value
        let staleElectrumResult = await electrumConnection.value
        XCTAssertTrue(wipeFinished)
        XCTAssertNil(staleResult)
        XCTAssertNil(staleElectrumResult)
        clearServerPreferencesAndReset()
        settings.endServerSettingsWipe()

        settings.rgsServerUrl = "https://new.example.com/snapshot"
        let rgsResult = await settings.connectToRgsServer(checkEndpoint: { _ in true }, restartNode: { _, _ in })
        XCTAssertEqual(rgsResult?.success, true)
        XCTAssertEqual(settings.rgsConfigService.getCurrentServerUrl(), "https://new.example.com/snapshot")
        XCTAssertFalse(settings.rgsIsLoading)

        setOldElectrumForm()
        let electrumResult = await settings.connectToElectrumServer(
            restartNode: { _, _ in }, waitForConnection: {}, isNodeRunning: { true }
        )
        XCTAssertEqual(electrumResult?.success, true)
        XCTAssertEqual(settings.electrumConfigService.getStoredServer()?.host, "old.example.com")
        XCTAssertTrue(settings.electrumIsConnected)
        XCTAssertFalse(settings.electrumIsLoading)
    }

    func testInvalidSettingsStillReturnFailureInsteadOfCancellation() async {
        settings.rgsServerUrl = "http://invalid.example.com"
        let rgs = await settings.connectToRgsServer(checkEndpoint: { _ in
            XCTFail("Invalid URL should not be checked")
            return true
        }, restartNode: { _, _ in XCTFail("Invalid URL should not restart the node") })
        XCTAssertEqual(rgs?.success, false)
        XCTAssertFalse(settings.rgsIsLoading)

        settings.electrumHost = ""
        let electrum = await settings.connectToElectrumServer(restartNode: { _, _ in
            XCTFail("Invalid host should not restart the node")
        }, waitForConnection: {}, isNodeRunning: { true })
        XCTAssertEqual(electrum?.success, false)
        XCTAssertFalse(settings.electrumIsLoading)
    }

    func testConnectionFailuresStillReturnResultsAndClearLoading() async {
        settings.rgsServerUrl = "https://old.example.com/snapshot"
        let unreachable = await settings.connectToRgsServer(checkEndpoint: { _ in false }, restartNode: { _, _ in
            XCTFail("Unreachable endpoint must not restart the node")
        })
        XCTAssertEqual(unreachable?.success, false)
        XCTAssertFalse(settings.rgsIsLoading)

        let rgsFailure = await settings.connectToRgsServer(checkEndpoint: { _ in true }, restartNode: { _, _ in
            throw TestError.restartFailed
        })
        XCTAssertEqual(rgsFailure?.success, false)
        XCTAssertNotNil(rgsFailure?.errorMessage)
        XCTAssertFalse(settings.rgsIsLoading)

        setOldElectrumForm()
        let electrumFailure = await settings.connectToElectrumServer(restartNode: { _, _ in
            throw TestError.restartFailed
        }, waitForConnection: {}, isNodeRunning: { true })
        XCTAssertEqual(electrumFailure?.success, false)
        XCTAssertFalse(settings.electrumIsLoading)

        setOldElectrumForm()
        let stoppedNode = await settings.connectToElectrumServer(
            restartNode: { _, _ in }, waitForConnection: {}, isNodeRunning: { false }
        )
        XCTAssertEqual(stoppedNode?.success, false)
        XCTAssertFalse(settings.electrumIsLoading)
    }

    func testCallerCancellationStopsConnectionAndClearsLoadingWithoutReset() async {
        let endpoint = ConnectionGate<Bool>()
        settings.rgsServerUrl = "https://old.example.com/snapshot"
        let connection = Task {
            await settings.connectToRgsServer(checkEndpoint: { _ in await endpoint.wait() }, restartNode: { _, _ in
                XCTFail("Cancelled request must not restart the node")
            })
        }
        await fulfillment(of: [endpoint.started], timeout: 3)
        connection.cancel()
        endpoint.resume(true)

        let result = await connection.value
        XCTAssertNil(result)
        XCTAssertFalse(settings.rgsIsLoading)
    }

    private func clearServerPreferencesAndReset() {
        UserDefaults.standard.removeObject(forKey: "electrumServer")
        UserDefaults.standard.removeObject(forKey: "rapidGossipSyncUrl")
        settings.resetToDefaults()
    }

    private func setOldElectrumForm() {
        settings.electrumHost = "old.example.com"
        settings.electrumPort = "50001"
        settings.electrumSelectedProtocol = .tcp
    }

    private enum TestError: Error {
        case restartFailed
    }
}

@MainActor
private final class ConnectionGate<Value> {
    let started = XCTestExpectation(description: "Connection reached suspended operation")
    private var continuation: CheckedContinuation<Value, Never>?

    func wait() async -> Value {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func resume(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
