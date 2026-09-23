@testable import Bitkit
import XCTest

@MainActor
final class LdkOfflineReceiveProviderTests: XCTestCase {
    private let nodeId = "02aa000000000000000000000000000000000000000000000000000000000000aa"
    private let bolt11 = "lnbcrt10u1ready"

    func testReadyInvoiceIsReturnedAfterPollingAndKeepsIdentityForRetries() async throws {
        let client = FakeOfflineReceiveNodeClient(nodeId: nodeId)
        client.statuses = [.awaitingActivation, .awaitingWitnesses, .ready(bolt11: bolt11)]
        let store = InMemoryOfflineReceiveRequestStore()
        let clock = FakeClock()
        let provider = makeProvider(client: client, store: store, clock: clock)

        let invoice = try await provider.prepareInvoice(requestId: "request-1", amountSats: 1000, description: "Coffee")

        XCTAssertEqual(invoice.bolt11, bolt11)
        XCTAssertEqual(client.prepareCalls.map(\.requestId), ["request-1"])
        XCTAssertEqual(client.prepareCalls.first?.amountMsat, 1_000_000)
        XCTAssertEqual(client.prepareCalls.first?.description, "Coffee")
        XCTAssertEqual(client.statusCalls, ["request-1", "request-1", "request-1"])
        XCTAssertEqual(clock.sleeps.count, 3)
        XCTAssertEqual(store.records, [OfflineReceiveRequestRecord(requestId: "request-1", amountSats: 1000, description: "Coffee")])
    }

    func testImmediatelyReadyRequestDoesNotPoll() async throws {
        let client = FakeOfflineReceiveNodeClient(nodeId: nodeId)
        client.prepareResult = .success(.ready(bolt11: bolt11))
        let clock = FakeClock()
        let provider = makeProvider(client: client, clock: clock)

        let invoice = try await provider.prepareInvoice(requestId: "request-1", amountSats: 1000, description: "")

        XCTAssertEqual(invoice.bolt11, bolt11)
        XCTAssertTrue(client.statusCalls.isEmpty)
        XCTAssertTrue(clock.sleeps.isEmpty)
    }

    func testTimeoutStopsPollingAndRetryResumesTheSameRequest() async throws {
        let client = FakeOfflineReceiveNodeClient(nodeId: nodeId)
        client.statuses = [.preparing]
        let store = InMemoryOfflineReceiveRequestStore()
        let clock = FakeClock(secondsPerSleep: 10)
        let provider = makeProvider(client: client, store: store, clock: clock, timeout: 60)

        await assertThrows(OfflineReceiveError.unavailable) {
            _ = try await provider.prepareInvoice(requestId: "request-1", amountSats: 1000, description: "")
        }
        XCTAssertEqual(clock.sleeps.count, 6)
        XCTAssertEqual(client.prepareCalls.count, 1)
        XCTAssertEqual(store.records.map(\.requestId), ["request-1"])

        client.statuses = [.ready(bolt11: bolt11)]
        let invoice = try await provider.prepareInvoice(requestId: "request-1", amountSats: 1000, description: "")

        XCTAssertEqual(invoice.bolt11, bolt11)
        XCTAssertEqual(client.prepareCalls.count, 1)
    }

    func testTerminalStatesMapToUnavailableAndClearIdentity() async {
        for terminal in [
            OfflineReceiveNodeStatus.expired,
            .settled(fulfilled: true),
            .settled(fulfilled: false),
            .failed(reason: "settlement node offline"),
        ] {
            let client = FakeOfflineReceiveNodeClient(nodeId: nodeId)
            client.prepareResult = .success(.preparing)
            client.statuses = [terminal]
            let store = InMemoryOfflineReceiveRequestStore()
            let provider = makeProvider(client: client, store: store)

            await assertThrows(OfflineReceiveError.unavailable) {
                _ = try await provider.prepareInvoice(requestId: "request-1", amountSats: 1000, description: "")
            }
            XCTAssertTrue(store.records.isEmpty, "\(terminal) must forget the request identity")
            XCTAssertTrue(client.cancelCalls.isEmpty)
        }
    }

    func testNodeErrorsDuringPreparationMapToUnavailableAndClearIdentity() async {
        for nodeError in [OfflineReceiveNodeError.disabled, .unavailable, .ineligible, .requestConflict] {
            let client = FakeOfflineReceiveNodeClient(nodeId: nodeId)
            client.prepareResult = .failure(nodeError)
            let store = InMemoryOfflineReceiveRequestStore()
            let provider = makeProvider(client: client, store: store)

            await assertThrows(OfflineReceiveError.unavailable) {
                _ = try await provider.prepareInvoice(requestId: "request-1", amountSats: 1000, description: "")
            }
            XCTAssertTrue(store.records.isEmpty, "\(nodeError) must forget the request identity")
        }
    }

    func testCanReceiveMapsNodeErrorsToFalseAndUsesMillisatoshis() async throws {
        let client = FakeOfflineReceiveNodeClient(nodeId: nodeId)
        let provider = makeProvider(client: client)

        let supported = try await provider.canReceive(amountSats: 1000)
        XCTAssertTrue(supported)
        XCTAssertEqual(client.canReceiveCalls, [1_000_000])

        for nodeError in [OfflineReceiveNodeError.disabled, .unavailable, .ineligible] {
            client.canReceiveResult = .failure(nodeError)
            let result = try await provider.canReceive(amountSats: 1000)
            XCTAssertFalse(result, "\(nodeError) must not advertise offline support")
        }

        client.canReceiveResult = .success(true)
        let zero = try await provider.canReceive(amountSats: 0)
        XCTAssertFalse(zero)
        let overflow = try await provider.canReceive(amountSats: UInt64.max)
        XCTAssertFalse(overflow)
        XCTAssertEqual(client.canReceiveCalls.count, 4)
    }

    func testRestartRecoversReadyInvoiceWithoutPreparingAgain() async throws {
        let stored = OfflineReceiveRequestRecord(requestId: "before-restart", amountSats: 1000, description: "Coffee")
        let store = InMemoryOfflineReceiveRequestStore(records: [stored])
        let client = FakeOfflineReceiveNodeClient(nodeId: nodeId)
        client.statuses = [.ready(bolt11: bolt11)]
        let provider = makeProvider(client: client, store: store)

        let invoice = try await provider.prepareInvoice(requestId: "after-restart", amountSats: 1000, description: "Coffee")

        XCTAssertEqual(invoice.bolt11, bolt11)
        XCTAssertTrue(client.prepareCalls.isEmpty)
        XCTAssertEqual(client.statusCalls, ["before-restart"])
        XCTAssertEqual(store.records, [stored])
    }

    func testRestartWithPendingRequestKeepsPollingTheStoredIdentity() async throws {
        let stored = OfflineReceiveRequestRecord(requestId: "before-restart", amountSats: 1000, description: "Coffee")
        let store = InMemoryOfflineReceiveRequestStore(records: [stored])
        let client = FakeOfflineReceiveNodeClient(nodeId: nodeId)
        client.statuses = [.awaitingWitnesses, .ready(bolt11: bolt11)]
        let provider = makeProvider(client: client, store: store)

        _ = try await provider.prepareInvoice(requestId: "after-restart", amountSats: 1000, description: "Coffee")

        XCTAssertTrue(client.prepareCalls.isEmpty)
        XCTAssertEqual(client.statusCalls, ["before-restart", "before-restart"])
    }

    func testRestartWithForgottenRequestPreparesWithTheNewIdentity() async throws {
        let stored = OfflineReceiveRequestRecord(requestId: "before-restart", amountSats: 1000, description: "Coffee")
        let store = InMemoryOfflineReceiveRequestStore(records: [stored])
        let client = FakeOfflineReceiveNodeClient(nodeId: nodeId)
        client.statusError = OfflineReceiveNodeError.requestNotFound
        client.prepareResult = .success(.ready(bolt11: bolt11))
        let provider = makeProvider(client: client, store: store)

        _ = try await provider.prepareInvoice(requestId: "after-restart", amountSats: 1000, description: "Coffee")

        XCTAssertEqual(client.statusCalls, ["before-restart"])
        XCTAssertEqual(client.prepareCalls.map(\.requestId), ["after-restart"])
        XCTAssertEqual(store.records.map(\.requestId), ["after-restart"])
    }

    func testDifferentIntentUsesItsOwnIdentityWithoutCancellingTheOldRequest() async throws {
        let stored = OfflineReceiveRequestRecord(requestId: "before-restart", amountSats: 1000, description: "Coffee")
        let store = InMemoryOfflineReceiveRequestStore(records: [stored])
        let client = FakeOfflineReceiveNodeClient(nodeId: nodeId)
        client.prepareResult = .success(.ready(bolt11: bolt11))
        client.inspectedAmountMsat = 2_000_000
        let provider = makeProvider(client: client, store: store)

        _ = try await provider.prepareInvoice(requestId: "edited", amountSats: 2000, description: "Coffee")

        XCTAssertEqual(client.prepareCalls.map(\.requestId), ["edited"])
        XCTAssertTrue(client.statusCalls.isEmpty)
        XCTAssertTrue(client.cancelCalls.isEmpty)
        XCTAssertEqual(store.records.map(\.requestId), ["before-restart", "edited"])
    }

    func testTaskCancellationStopsPollingWithoutCancellingTheNodeRequest() async {
        let client = FakeOfflineReceiveNodeClient(nodeId: nodeId)
        client.statuses = [.preparing]
        let store = InMemoryOfflineReceiveRequestStore()
        let polling = expectation(description: "provider is waiting between polls")
        let provider = LdkOfflineReceiveProvider(
            client: client,
            store: store,
            inspect: client.inspect,
            sleep: { _ in
                polling.fulfill()
                try await Task.sleep(nanoseconds: 30_000_000_000)
            }
        )

        let task = Task { try await provider.prepareInvoice(requestId: "request-1", amountSats: 1000, description: "") }
        await fulfillment(of: [polling], timeout: 2)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled preparation must not return an invoice")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
        XCTAssertTrue(client.cancelCalls.isEmpty)
        XCTAssertEqual(store.records.map(\.requestId), ["request-1"])
    }

    func testCancelReleasesNodeRequestAndForgetsIdentity() async throws {
        let stored = OfflineReceiveRequestRecord(requestId: "request-1", amountSats: 1000, description: "")
        let store = InMemoryOfflineReceiveRequestStore(records: [stored])
        let client = FakeOfflineReceiveNodeClient(nodeId: nodeId)
        let provider = makeProvider(client: client, store: store)

        try await provider.cancel(requestId: "request-1")
        XCTAssertEqual(client.cancelCalls, ["request-1"])
        XCTAssertTrue(store.records.isEmpty)

        store.save([stored])
        client.cancelError = OfflineReceiveNodeError.requestNotFound
        try await provider.cancel(requestId: "request-1")
        XCTAssertTrue(store.records.isEmpty)
    }

    func testReadyInvoiceWithWrongAmountOrPayeeIsRejected() async {
        for (amountMsat, payee) in [(999_000, nodeId), (1_000_000, "03bb000000000000000000000000000000000000000000000000000000000000bb")] {
            let client = FakeOfflineReceiveNodeClient(nodeId: nodeId)
            client.prepareResult = .success(.ready(bolt11: bolt11))
            client.inspectedAmountMsat = UInt64(amountMsat)
            client.inspectedPayee = payee
            let store = InMemoryOfflineReceiveRequestStore()
            let provider = makeProvider(client: client, store: store)

            await assertThrows(OfflineReceiveError.invalidInvoice) {
                _ = try await provider.prepareInvoice(requestId: "request-1", amountSats: 1000, description: "")
            }
            XCTAssertTrue(store.records.isEmpty)
        }
    }

    func testUnparsableReadyInvoiceIsRejected() async {
        let client = FakeOfflineReceiveNodeClient(nodeId: nodeId)
        client.prepareResult = .success(.ready(bolt11: bolt11))
        client.inspectError = TestFailure.parse
        let provider = makeProvider(client: client)

        await assertThrows(OfflineReceiveError.invalidInvoice) {
            _ = try await provider.prepareInvoice(requestId: "request-1", amountSats: 1000, description: "")
        }
    }

    func testDeveloperGateHidesProviderUntilEnabled() async throws {
        let inner = CountingProvider()
        var enabled = false
        let gated = DeveloperGatedOfflineReceiveProvider(isEnabled: { enabled }, provider: inner)

        let hidden = try await gated.canReceive(amountSats: 1000)
        XCTAssertFalse(hidden)
        await assertThrows(OfflineReceiveError.unavailable) {
            _ = try await gated.prepareInvoice(requestId: "request-1", amountSats: 1000, description: "")
        }
        XCTAssertEqual(inner.canReceiveCount, 0)
        XCTAssertEqual(inner.prepareCount, 0)

        enabled = true
        let visible = try await gated.canReceive(amountSats: 1000)
        XCTAssertTrue(visible)
        _ = try await gated.prepareInvoice(requestId: "request-1", amountSats: 1000, description: "")
        XCTAssertEqual(inner.canReceiveCount, 1)
        XCTAssertEqual(inner.prepareCount, 1)
    }

    func testDefaultBuildSelectsTheUnavailableProvider() {
        XCTAssertFalse(OfflineReceiveSettings.isBuildAvailable)
        XCTAssertTrue(OfflineReceiveProviderSelection.provider() is UnavailableOfflineReceiveProvider)
    }

    func testUserDefaultsStoreRoundTripsAndCapsRecords() {
        let suite = "LdkOfflineReceiveProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsOfflineReceiveRequestStore(defaults: defaults)

        for index in 0 ..< 20 {
            store.remember(OfflineReceiveRequestRecord(requestId: "request-\(index)", amountSats: UInt64(index + 1), description: ""))
        }
        XCTAssertEqual(store.load().count, 16)
        XCTAssertEqual(store.load().last?.requestId, "request-19")
        XCTAssertNil(store.record(amountSats: 1, description: ""))
        XCTAssertEqual(store.record(amountSats: 20, description: "")?.requestId, "request-19")

        store.remember(OfflineReceiveRequestRecord(requestId: "replacement", amountSats: 20, description: ""))
        XCTAssertEqual(store.record(amountSats: 20, description: "")?.requestId, "replacement")
        XCTAssertEqual(store.load().count, 16)

        let reopened = UserDefaultsOfflineReceiveRequestStore(defaults: defaults)
        XCTAssertEqual(reopened.load(), store.load())

        for record in store.load() {
            store.forget(requestId: record.requestId)
        }
        XCTAssertNil(defaults.object(forKey: UserDefaultsOfflineReceiveRequestStore.key))
    }

    func testNodeConfigurationRequiresToggleAndValidNodeIds() {
        let suite = "OfflineReceiveSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let lsp = LnPeer(nodeId: "03cc000000000000000000000000000000000000000000000000000000000000cc", host: "lsp", port: 9735)

        XCTAssertNil(OfflineReceiveSettings.nodeConfiguration(defaults: defaults, trustedPeers: [lsp]))
        XCTAssertFalse(OfflineReceiveSettings.isEnabled(defaults: defaults))

        defaults.set(true, forKey: OfflineReceiveSettings.enabledKey)
        XCTAssertFalse(OfflineReceiveSettings.isEnabled(defaults: defaults), "The provider gate also needs the local binding build")
        let fromLsp = OfflineReceiveSettings.nodeConfiguration(defaults: defaults, trustedPeers: [lsp])
        XCTAssertEqual(fromLsp?.settlementNodeId, lsp.nodeId)
        XCTAssertEqual(fromLsp?.witnessNodeIds, [])
        XCTAssertEqual(fromLsp?.invoiceExpirySeconds, 3600)
        XCTAssertEqual(fromLsp?.settlementDeadlineBlocks, 144)

        XCTAssertNil(OfflineReceiveSettings.nodeConfiguration(defaults: defaults, trustedPeers: []))

        defaults.set("not-a-node-id", forKey: OfflineReceiveSettings.settlementNodeIdKey)
        XCTAssertEqual(OfflineReceiveSettings.nodeConfiguration(defaults: defaults, trustedPeers: [lsp])?.settlementNodeId, lsp.nodeId)

        defaults.set(" \(nodeId.uppercased()) ", forKey: OfflineReceiveSettings.settlementNodeIdKey)
        defaults.set(
            "\(nodeId), 02dd000000000000000000000000000000000000000000000000000000000000dd,bad, \(lsp.nodeId)\n\(lsp.nodeId)",
            forKey: OfflineReceiveSettings.witnessNodeIdsKey
        )
        let custom = OfflineReceiveSettings.nodeConfiguration(defaults: defaults, trustedPeers: [lsp])
        XCTAssertEqual(custom?.settlementNodeId, nodeId)
        XCTAssertEqual(custom?.witnessNodeIds, ["02dd000000000000000000000000000000000000000000000000000000000000dd", lsp.nodeId])
    }

    private func makeProvider(
        client: FakeOfflineReceiveNodeClient,
        store: InMemoryOfflineReceiveRequestStore? = nil,
        clock: FakeClock? = nil,
        timeout: TimeInterval = 60
    ) -> LdkOfflineReceiveProvider {
        let store = store ?? InMemoryOfflineReceiveRequestStore()
        let clock = clock ?? FakeClock()
        return LdkOfflineReceiveProvider(
            client: client,
            store: store,
            inspect: client.inspect,
            timeout: timeout,
            pollInterval: 0.5,
            now: { clock.now },
            sleep: { try await clock.sleep($0) }
        )
    }

    private func assertThrows(_ expected: OfflineReceiveError, _ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as OfflineReceiveError {
            XCTAssertEqual(error.localizedDescription, expected.localizedDescription)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private enum TestFailure: Error {
    case parse
}

@MainActor
private final class FakeClock {
    private(set) var now = Date(timeIntervalSince1970: 1_700_000_000)
    private(set) var sleeps: [TimeInterval] = []
    private let secondsPerSleep: TimeInterval?

    init(secondsPerSleep: TimeInterval? = nil) {
        self.secondsPerSleep = secondsPerSleep
    }

    func sleep(_ interval: TimeInterval) async throws {
        try Task.checkCancellation()
        sleeps.append(interval)
        now = now.addingTimeInterval(secondsPerSleep ?? interval)
        await Task.yield()
    }
}

@MainActor
private final class FakeOfflineReceiveNodeClient: OfflineReceiveNodeClient {
    let nodeIdValue: String
    var canReceiveResult: Result<Bool, Error> = .success(true)
    var prepareResult: Result<OfflineReceiveNodeStatus, Error> = .success(.preparing)
    var statuses: [OfflineReceiveNodeStatus] = []
    var statusError: Error?
    var cancelError: Error?
    var inspectedAmountMsat: UInt64? = 1_000_000
    var inspectedPayee: String?
    var inspectError: Error?

    private(set) var canReceiveCalls: [UInt64] = []
    private(set) var prepareCalls: [(requestId: String, amountMsat: UInt64, description: String)] = []
    private(set) var statusCalls: [String] = []
    private(set) var cancelCalls: [String] = []

    init(nodeId: String) {
        nodeIdValue = nodeId
    }

    func nodeId() async throws -> String { nodeIdValue }

    func canReceive(amountMsat: UInt64) async throws -> Bool {
        canReceiveCalls.append(amountMsat)
        return try canReceiveResult.get()
    }

    func prepare(requestId: String, amountMsat: UInt64, description: String) async throws -> OfflineReceiveNodeStatus {
        prepareCalls.append((requestId, amountMsat, description))
        return try prepareResult.get()
    }

    func status(requestId: String) async throws -> OfflineReceiveNodeStatus {
        statusCalls.append(requestId)
        if let statusError { throw statusError }
        guard !statuses.isEmpty else { throw OfflineReceiveNodeError.requestNotFound }
        return statuses.count > 1 ? statuses.removeFirst() : statuses[0]
    }

    func cancel(requestId: String) async throws {
        cancelCalls.append(requestId)
        if let cancelError { throw cancelError }
    }

    func inspect(_: String) throws -> OfflineReceiveInvoiceSummary {
        if let inspectError { throw inspectError }
        return OfflineReceiveInvoiceSummary(amountMsat: inspectedAmountMsat, payeeNodeId: inspectedPayee ?? nodeIdValue)
    }
}

@MainActor
private final class CountingProvider: OfflineReceiveProviding {
    private(set) var canReceiveCount = 0
    private(set) var prepareCount = 0

    func canReceive(amountSats _: UInt64) async throws -> Bool {
        canReceiveCount += 1
        return true
    }

    func prepareInvoice(requestId _: String, amountSats _: UInt64, description _: String) async throws -> PreparedOfflineInvoice {
        prepareCount += 1
        return PreparedOfflineInvoice(bolt11: "gated-invoice")
    }
}
