@testable import Bitkit
import LDKNode
import XCTest

final class OnchainSendAttemptServiceTests: XCTestCase {
    private let walletId = "node-0"
    private let txid = String(repeating: "ab", count: 32)

    func testConcurrentAdmissionPersistsOnlyOnePendingAttempt() async {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let walletId = walletId

        let admitted = await withTaskGroup(of: UUID?.self) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    try? await service.admit(
                        walletId: walletId,
                        requestId: nil,
                        orderId: nil,
                        address: "bcrt1qexample",
                        amountSats: 1000,
                        isMaxAmount: false
                    )
                }
            }
            var ids: [UUID] = []
            for await id in group {
                if let id {
                    ids.append(id)
                }
            }
            return ids
        }

        XCTAssertEqual(admitted.count, 1)
        XCTAssertEqual(store.snapshot().count, 1)
        XCTAssertEqual(store.snapshot().first?.status, .pending)
    }

    func testReadAndWriteFailuresPreventAdmission() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        store.failLoad = true
        do {
            _ = try await admit(service)
            XCTFail("Read failure admitted a send")
        } catch {}

        store.failLoad = false
        store.failSave = true
        do {
            _ = try await admit(service)
            XCTFail("Write failure admitted a send")
        } catch {}
        XCTAssertTrue(store.snapshot().isEmpty)
    }

    func testPendingWithoutTxidStillBlocksAfterServiceRestart() async throws {
        let store = MemoryAttemptStore()
        _ = try await admit(OnchainSendAttemptService(store: store))
        let restarted = OnchainSendAttemptService(store: store)

        do {
            _ = try await admit(restarted)
            XCTFail("A crash gap without a txid admitted another send")
        } catch let error as OnchainSendAttemptError {
            guard case .unresolved = error else { return XCTFail("Expected an unresolved-attempt guard") }
        }
        XCTAssertNil(store.snapshot().first?.txid)
    }

    func testRejectedAndUnknownRetainTxidAndBlockAnotherSend() async throws {
        for result in [OnchainSendResult.rejected(txid: txid, reason: "non-final"), .unknown(txid: txid)] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let id = try await admit(service)
            try await service.record(result, attemptId: id)
            XCTAssertEqual(store.snapshot().first?.txid, txid)
            do {
                _ = try await admit(service)
                XCTFail("Unresolved outcome admitted a second send")
            } catch {}
        }
    }

    func testAcceptedIsDurableAndAllowsDistinctNewSend() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let firstId = try await admit(service)
        try await service.record(.accepted(txid: txid), attemptId: firstId)
        try await service.acknowledgeLocalFollowup(txid: txid)
        let nextId = try await admit(service)

        XCTAssertNotEqual(firstId, nextId)
        XCTAssertEqual(store.snapshot().count, 1)
        XCTAssertEqual(store.snapshot().first?.status, .pending)
    }

    func testAcceptedOrderCannotBeFundedAgain() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let id = try await service.admit(
            walletId: walletId, requestId: nil, orderId: "order-1",
            address: "bcrt1qexample", amountSats: 1000, isMaxAmount: false
        )
        try await service.record(.accepted(txid: txid), attemptId: id)
        try await service.acknowledgeLocalFollowup(txid: txid)

        do {
            _ = try await service.admit(
                walletId: walletId, requestId: nil, orderId: "order-1",
                address: "bcrt1qexample", amountSats: 1000, isMaxAmount: false
            )
            XCTFail("Accepted order admitted a second funding payment")
        } catch let error as OnchainSendAttemptError {
            guard case .duplicate = error else { return XCTFail("Expected a duplicate-payment guard") }
        }
    }

    func testOutcomeWriteFailureRetainsPendingGuard() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let id = try await admit(service)
        store.failSave = true
        do {
            try await service.record(.accepted(txid: txid), attemptId: id)
            XCTFail("Outcome write unexpectedly succeeded")
        } catch {}
        XCTAssertEqual(store.snapshot().first?.status, .pending)
    }

    func testOnlyMatchingPreDispatchGuardCanBeCleared() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let id = try await admit(service)

        try await service.clearBeforeDispatch(attemptId: UUID())
        XCTAssertEqual(store.snapshot().first?.id, id)

        try await service.clearBeforeDispatch(attemptId: id)
        XCTAssertTrue(store.snapshot().isEmpty)

        let acceptedId = try await admit(service)
        try await service.record(.accepted(txid: txid), attemptId: acceptedId)
        try await service.clearBeforeDispatch(attemptId: acceptedId)
        XCTAssertEqual(store.snapshot().first?.status, .accepted)
    }

    func testOnlyExactConfirmedTxidResolvesUnknownAttempt() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let id = try await admit(service)
        try await service.record(.unknown(txid: txid), attemptId: id)

        let unrelatedObserved = try await service.observeConfirmedTransaction(txid: String(repeating: "cd", count: 32))
        XCTAssertFalse(unrelatedObserved)
        XCTAssertEqual(store.snapshot().first?.status, .unknown)
        let exactObserved = try await service.observeConfirmedTransaction(txid: txid)
        XCTAssertTrue(exactObserved)
        XCTAssertEqual(store.snapshot().first?.status, .accepted)
    }

    func testSendPreservesAcceptedWhenOutcomeStorageFailsAndRestartBlocksDispatch() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let node = AttemptNodeMock(result: .accepted(txid: txid))
        do {
            let result = try await service.send(
                using: node, address: "bcrt1qexample", amountSats: 1000,
                satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false
            ) {
                store.failSave = true
            }
            guard case let .accepted(returnedTxid) = result else { return XCTFail("Lost known acceptance") }
            XCTAssertEqual(returnedTxid, txid)
        } catch {
            XCTFail("Known Accepted result became a generic error: \(error)")
        }
        XCTAssertEqual(node.calls, 1)
        XCTAssertEqual(store.snapshot().first?.status, .pending)
        XCTAssertNil(store.snapshot().first?.txid)
        store.failSave = false
        let restarted = OnchainSendAttemptService(store: store)
        do {
            _ = try await restarted.send(
                using: node, address: "bcrt1qother", amountSats: 2000,
                satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: true
            )
            XCTFail("Restart bypassed pending guard")
        } catch {}
        XCTAssertEqual(node.calls, 1)
    }

    func testCompletedOrdinarySendsDoNotAccumulateHistory() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        for _ in 0 ..< 50 {
            let id = try await admit(service)
            try await service.record(.accepted(txid: txid), attemptId: id)
            try await service.acknowledgeLocalFollowup(txid: txid)
            XCTAssertEqual(store.snapshot().count, 1, "Attempt guard grew into ordinary send history")
        }
        _ = try await admit(service)
        XCTAssertEqual(store.snapshot().count, 1)
    }

    func testCompletedOrdinaryGuardCanBeReplacedAcrossWallets() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let id = try await admit(service)
        try await service.record(.accepted(txid: txid), attemptId: id)
        do {
            _ = try await service.admit(
                walletId: "node-1", requestId: nil, orderId: nil,
                address: "bcrt1qother", amountSats: 2000, isMaxAmount: false
            )
            XCTFail("Incomplete accepted follow-up stopped guarding other wallets")
        } catch {}
        try await service.acknowledgeLocalFollowup(txid: txid)
        _ = try await service.admit(
            walletId: "node-1", requestId: nil, orderId: nil,
            address: "bcrt1qother", amountSats: 2000, isMaxAmount: false
        )
        XCTAssertEqual(store.snapshot().count, 1)
        XCTAssertEqual(store.snapshot().first?.walletId, "node-1")
        XCTAssertEqual(store.snapshot().first?.status, .pending)
    }

    func testWalletOrNodeChangeDuringCallbackDoesNotDispatch() async throws {
        for changeWalletIndex in [true, false] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let node = AttemptNodeMock(result: .accepted(txid: txid))
            do {
                _ = try await service.send(
                    using: node, address: "bcrt1qexample", amountSats: 1000,
                    satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false
                ) {
                    if changeWalletIndex {
                        node.currentWalletIndex = 1
                    } else {
                        node.dispatchNode = NSObject()
                    }
                }
                XCTFail("Dispatch used a different wallet or node after admission")
            } catch let error as OnchainSendAttemptError {
                guard case .preDispatch = error else { return XCTFail("Expected known pre-dispatch failure") }
            }
            XCTAssertEqual(node.calls, 0)
            XCTAssertTrue(store.snapshot().isEmpty, "Known pre-dispatch failure retained an attempt")
        }
    }

    func testAcceptedBlocksNewSendUntilMatchingDurableFollowup() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let id = try await admit(service)
        try await service.record(.accepted(txid: txid), attemptId: id)
        try await service.acknowledgeLocalFollowup(txid: String(repeating: "cd", count: 32))
        do { _ = try await admit(service); XCTFail("Accepted without follow-up admitted new send") } catch {}
        store.failSave = true
        do { try await service.acknowledgeLocalFollowup(txid: txid); XCTFail("Follow-up save should fail") } catch {}
        store.failSave = false
        let restarted = OnchainSendAttemptService(store: store)
        do { _ = try await admit(restarted); XCTFail("Restart lost incomplete follow-up") } catch {}
        XCTAssertEqual(store.snapshot().first?.status, .accepted)
        XCTAssertEqual(store.snapshot().first?.localFollowupComplete, false)
        try await restarted.acknowledgeLocalFollowup(txid: txid)
        _ = try await admit(restarted)
        XCTAssertEqual(store.snapshot().count, 1)
    }

    func testAcceptedOrderResumesWithoutAnotherNodeCallAfterRestart() async throws {
        let store = MemoryAttemptStore()
        let node = AttemptNodeMock(result: .accepted(txid: txid))
        let service = OnchainSendAttemptService(store: store)
        _ = try await send(service, node: node, orderId: "order-1")
        let restarted = OnchainSendAttemptService(store: store)
        let result = try await send(restarted, node: node, orderId: "order-1", isMaxAmount: true)
        guard case let .accepted(savedTxid) = result else { return XCTFail("Lost accepted prior result") }
        XCTAssertEqual(savedTxid, txid)
        XCTAssertEqual(node.calls, 1)
    }

    func testPaidOrderStoreProtectsOlderOrderAfterCurrentAttemptIsReplaced() async throws {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store, hasPaidOrder: { $0 == "paid-order" })
        let id = try await admit(service)
        try await service.record(.accepted(txid: txid), attemptId: id)
        try await service.acknowledgeLocalFollowup(txid: txid)
        _ = try await admit(service)
        let node = AttemptNodeMock(result: .unknown(txid: txid))
        do {
            _ = try await send(service, node: node, orderId: "paid-order")
            XCTFail("Older paid order was dispatched again")
        } catch let error as OnchainSendAttemptError {
            guard case .duplicate = error else { return XCTFail("Expected paid-order guard") }
        }
        XCTAssertEqual(node.calls, 0)
        XCTAssertEqual(store.snapshot().first?.status, .pending)
    }

    func testActualSendSerializesFixedMaxAndTransferBeforeNodeDispatch() async {
        let store = MemoryAttemptStore()
        let service = OnchainSendAttemptService(store: store)
        let node = AttemptNodeMock(result: .unknown(txid: txid))
        node.onSend = {
            XCTAssertEqual(store.snapshot().first?.status, .pending)
            await Task.yield()
        }
        let results = await withTaskGroup(of: Bool.self) { group in
            for index in 0 ..< 20 {
                group.addTask {
                    do {
                        _ = try await service.send(
                            using: node, address: "bcrt1qexample", amountSats: 1000, satsPerVbyte: 1,
                            utxosToSpend: nil, isMaxAmount: index % 2 == 0, orderId: index % 3 == 0 ? "order" : nil
                        )
                        return true
                    } catch { return false }
                }
            }
            var count = 0
            for await sent in group {
                if sent {
                    count += 1
                }
            }
            return count
        }
        XCTAssertEqual(results, 1)
        XCTAssertEqual(node.calls, 1)
        XCTAssertEqual(store.snapshot().count, 1)
    }

    func testCallbackNodeErrorAndCancellationRetainGuardWithoutDispatch() async throws {
        for error in [NodeError.NotRunning(message: "callback failure") as Error, CancellationError()] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let node = AttemptNodeMock(result: .accepted(txid: txid))
            do {
                _ = try await service.send(
                    using: node, address: "bcrt1qexample", amountSats: 1000,
                    satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: false
                ) { throw error }
                XCTFail("Callback failure succeeded")
            } catch let error as OnchainSendAttemptError {
                guard case .unresolved = error else { return XCTFail("Callback error cleared preguard") }
            }
            XCTAssertEqual(node.calls, 0)
            XCTAssertEqual(store.snapshot().first?.status, .pending)
        }
    }

    func testOnlyNodePreDispatchErrorReleasesGuardAndSaveFailureRetainsIt() async throws {
        for failRelease in [false, true] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let node = AttemptNodeMock(result: .accepted(txid: txid))
            node.error = NodeError.NotRunning(message: "not running")
            node.onSend = { store.failSave = failRelease }
            do { _ = try await send(service, node: node); XCTFail("Node error succeeded") } catch let error as OnchainSendAttemptError {
                if failRelease {
                    guard case .unresolved = error else { return XCTFail("Release write failure lost guard") }
                } else {
                    guard case .preDispatch = error else { return XCTFail("Proven pre-dispatch error not released") }
                }
            }
            XCTAssertEqual(store.snapshot().isEmpty, !failRelease)
        }
    }

    func testGenericNodeWorkflowErrorsRetainGuard() async throws {
        for error in [MemoryAttemptStoreError.failed as Error, CancellationError()] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let node = AttemptNodeMock(result: .accepted(txid: txid))
            node.error = error
            do { _ = try await send(service, node: node); XCTFail("Node workflow error succeeded") } catch {}
            XCTAssertEqual(store.snapshot().first?.status, .pending)
        }
    }

    func testRejectedAndUnknownArePreservedWhenSavingTheirOutcomesFails() async throws {
        for result in [OnchainSendResult.rejected(txid: txid, reason: "non-final"), .unknown(txid: txid)] {
            let store = MemoryAttemptStore()
            let service = OnchainSendAttemptService(store: store)
            let node = AttemptNodeMock(result: result)
            node.onSend = { store.failSave = true }
            let returned = try await send(service, node: node, isMaxAmount: true)
            XCTAssertEqual(returned, result)
            store.failSave = false
            let current = try await service.unresolvedAttempt(walletId: OnchainSendAttemptService.walletId(index: 0))
            XCTAssertEqual(current?.txid, txid)
            XCTAssertEqual(store.snapshot().first?.status, .pending)
            do { _ = try await send(service, node: node); XCTFail("In-memory outcome allowed new send") } catch {}
            XCTAssertEqual(node.calls, 1)
        }
    }

    private func send(
        _ service: OnchainSendAttemptService, node: AttemptNodeMock, orderId: String? = nil, isMaxAmount: Bool = false
    ) async throws -> OnchainSendResult {
        try await service.send(
            using: node, address: "bcrt1qexample", amountSats: 1000,
            satsPerVbyte: 1, utxosToSpend: nil, isMaxAmount: isMaxAmount, orderId: orderId
        )
    }

    private func admit(_ service: OnchainSendAttemptService) async throws -> UUID {
        try await service.admit(
            walletId: walletId,
            requestId: nil,
            orderId: nil,
            address: "bcrt1qexample",
            amountSats: 1000,
            isMaxAmount: false
        )
    }
}

final class MemoryAttemptStore: OnchainSendAttemptStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [OnchainSendAttempt] = []
    var failLoad = false
    var failSave = false

    func load() throws -> [OnchainSendAttempt] {
        lock.lock()
        defer { lock.unlock() }
        if failLoad {
            throw MemoryAttemptStoreError.failed
        }
        return attempts
    }

    func save(_ attempts: [OnchainSendAttempt]) throws {
        lock.lock()
        defer { lock.unlock() }
        if failSave {
            throw MemoryAttemptStoreError.failed
        }
        self.attempts = attempts
    }

    func snapshot() -> [OnchainSendAttempt] {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }
}

private enum MemoryAttemptStoreError: Error {
    case failed
}

final class AttemptNodeMock: OnchainSending {
    var currentWalletIndex = 0
    var dispatchNode: AnyObject = NSObject()
    var onchainDispatchNode: AnyObject? {
        dispatchNode
    }

    var calls = 0
    var result: OnchainSendResult
    var error: Error?
    var onSend: (() async throws -> Void)?

    init(result: OnchainSendResult) {
        self.result = result
    }

    func send(address: String, sats: UInt64, satsPerVbyte: UInt32, utxosToSpend: [SpendableUtxo]?,
              isMaxAmount: Bool, expectedWalletIndex: Int?, expectedNode: AnyObject?) async throws -> OnchainSendResult
    {
        calls += 1
        try await onSend?()
        if let error {
            throw error
        }
        return result
    }
}
