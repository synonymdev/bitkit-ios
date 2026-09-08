@testable import Bitkit
import BitkitCore
import XCTest

@MainActor
final class BlocktankRefundAddressProviderTests: XCTestCase {
    private enum StubError: Error {
        case lookup
        case reveal
        case persist
        case estimate
        case submit
    }

    private final class State {
        var cached: BlocktankRefundAddress?
        var usedAddresses: Set<String> = []
        var allocationCount = 0
        var lookupCount = 0
        var revealCount = 0
    }

    private final class StubRefundProvider: BlocktankRefundAddressProviding {
        var callCount = 0
        var result: Result<String, Error>

        init(result: Result<String, Error>) {
            self.result = result
        }

        func addressForOrder() async throws -> String {
            callCount += 1
            return try result.get()
        }
    }

    override func setUp() {
        super.setUp()
        BlocktankRefundAddressStore().clear()
    }

    override func tearDown() {
        BlocktankRefundAddressStore().clear()
        super.tearDown()
    }

    private func makeProvider(
        state: State,
        lookup: ((UInt32) async throws -> BlocktankRefundAddress)? = nil,
        reveal: ((UInt32) async throws -> Void)? = nil,
        save: ((BlocktankRefundAddress) throws -> Void)? = nil,
        allocationDelayNanoseconds: UInt64 = 0
    ) -> BlocktankRefundAddressProvider {
        BlocktankRefundAddressProvider(
            load: { state.cached },
            save: save ?? { state.cached = $0 },
            lookup: lookup ?? { index in
                state.lookupCount += 1
                guard let cached = state.cached else { throw StubError.lookup }
                return BlocktankRefundAddress(address: cached.address, index: index)
            },
            reveal: reveal ?? { _ in state.revealCount += 1 },
            isUsed: { state.usedAddresses.contains($0) },
            allocate: {
                if allocationDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: allocationDelayNanoseconds)
                }
                let index = UInt32(state.allocationCount)
                state.allocationCount += 1
                return BlocktankRefundAddress(address: "refund-\(index)", index: index)
            }
        )
    }

    func testUnpaidAndFailedOrdersReuseOneAddressAcrossProviderRestarts() async throws {
        let state = State()

        for _ in 0 ..< 8 {
            let provider = makeProvider(state: state)
            let address = try await provider.addressForOrder()
            XCTAssertEqual(address, "refund-0")
        }

        XCTAssertEqual(state.allocationCount, 1)
        XCTAssertEqual(state.cached, BlocktankRefundAddress(address: "refund-0", index: 0))
    }

    func testRecordedPaymentRotatesExactlyOnce() async throws {
        let state = State()
        let provider = makeProvider(state: state)

        let firstAddress = try await provider.addressForOrder()
        XCTAssertEqual(firstAddress, "refund-0")
        state.usedAddresses.insert("refund-0")

        let rotatedAddress = try await provider.addressForOrder()
        let reusedAddress = try await provider.addressForOrder()
        XCTAssertEqual(rotatedAddress, "refund-1")
        XCTAssertEqual(reusedAddress, "refund-1")
        XCTAssertEqual(state.allocationCount, 2)
        XCTAssertEqual(state.cached, BlocktankRefundAddress(address: "refund-1", index: 1))
    }

    func testConcurrentCallsCoalesceOneAllocation() async throws {
        let state = State()
        let provider = makeProvider(state: state, allocationDelayNanoseconds: 50_000_000)

        async let first = provider.addressForOrder()
        async let second = provider.addressForOrder()
        async let third = provider.addressForOrder()
        let addresses = try await [first, second, third]

        XCTAssertEqual(addresses, ["refund-0", "refund-0", "refund-0"])
        XCTAssertEqual(state.allocationCount, 1)
    }

    func testCachedAddressIsLookedUpAndRevealedBeforeReuse() async throws {
        let state = State()
        state.cached = BlocktankRefundAddress(address: "refund-7", index: 7)
        let provider = makeProvider(state: state)

        let address = try await provider.addressForOrder()
        XCTAssertEqual(address, "refund-7")
        XCTAssertEqual(state.lookupCount, 1)
        XCTAssertEqual(state.revealCount, 1)
        XCTAssertEqual(state.allocationCount, 0)
    }

    func testOwnershipMismatchIsRejected() async {
        let state = State()
        state.cached = BlocktankRefundAddress(address: "other-wallet", index: 7)
        let provider = makeProvider(state: state, lookup: { index in
            BlocktankRefundAddress(address: "active-wallet", index: index)
        })

        await XCTAssertThrowsErrorAsync({ try await provider.addressForOrder() }) { error in
            XCTAssertEqual(error as? BlocktankRefundAddressError, .ownershipMismatch)
        }
        XCTAssertEqual(state.allocationCount, 0)
    }

    func testHardenedIndexIsRejected() async {
        let state = State()
        state.cached = BlocktankRefundAddress(address: "refund", index: UInt32(Int32.max) + 1)
        let provider = makeProvider(state: state)

        await XCTAssertThrowsErrorAsync({ try await provider.addressForOrder() }) { error in
            XCTAssertEqual(error as? BlocktankRefundAddressError, .indexOutOfRange(UInt32(Int32.max) + 1))
        }
        XCTAssertEqual(state.lookupCount, 0)
        XCTAssertEqual(state.allocationCount, 0)
    }

    func testLookupFailureDoesNotAllocate() async {
        let state = State()
        state.cached = BlocktankRefundAddress(address: "refund", index: 1)
        let provider = makeProvider(state: state, lookup: { _ in throw StubError.lookup })

        await XCTAssertThrowsErrorAsync { try await provider.addressForOrder() }
        XCTAssertEqual(state.allocationCount, 0)
    }

    func testRevealFailureDoesNotAllocate() async {
        let state = State()
        state.cached = BlocktankRefundAddress(address: "refund", index: 1)
        let provider = makeProvider(state: state, reveal: { _ in throw StubError.reveal })

        await XCTAssertThrowsErrorAsync { try await provider.addressForOrder() }
        XCTAssertEqual(state.allocationCount, 0)
    }

    func testCachePersistenceFailureReturnsNoAddress() async {
        let state = State()
        let provider = makeProvider(state: state, save: { _ in throw StubError.persist })

        await XCTAssertThrowsErrorAsync { try await provider.addressForOrder() }
        XCTAssertEqual(state.allocationCount, 1)
        XCTAssertNil(state.cached)
    }

    func testAppCacheSerializationMatchesSharedOptionalShape() throws {
        let json = #"{"blocktankRefundAddress":{"address":"bcrt1refund","index":7}}"#
        let cache = try JSONDecoder().decode(AppCacheData.self, from: Data(json.utf8))

        XCTAssertEqual(cache.blocktankRefundAddress, BlocktankRefundAddress(address: "bcrt1refund", index: 7))

        let encoded = try JSONEncoder().encode(cache)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let refund = try XCTUnwrap(object["blocktankRefundAddress"] as? [String: Any])
        XCTAssertEqual(refund["address"] as? String, "bcrt1refund")
        XCTAssertEqual(refund["index"] as? Int, 7)
    }

    func testOlderAppCacheWithoutRefundAddressDecodesAsNil() throws {
        let cache = try JSONDecoder().decode(AppCacheData.self, from: Data("{}".utf8))

        XCTAssertNil(cache.blocktankRefundAddress)
    }

    func testSettingsCacheRestoreRoundTripAndWipe() throws {
        let json = #"{"blocktankRefundAddress":{"address":"bcrt1refund","index":7}}"#
        let restored = try JSONDecoder().decode(AppCacheData.self, from: Data(json.utf8))

        try SettingsViewModel.shared.restoreAppCacheData(restored)

        XCTAssertEqual(
            try SettingsViewModel.shared.getAppCacheData().blocktankRefundAddress,
            BlocktankRefundAddress(address: "bcrt1refund", index: 7)
        )
        XCTAssertTrue(SettingsBackupConfig.appStateKeys.contains(BlocktankRefundAddressStore.key))

        SettingsViewModel.shared.resetToDefaults()
        XCTAssertNil(try BlocktankRefundAddressStore().load())
    }

    func testCorruptLocalCacheIsRejected() throws {
        UserDefaults.standard.set(Data("not-json".utf8), forKey: BlocktankRefundAddressStore.key)

        XCTAssertThrowsError(try BlocktankRefundAddressStore().load()) { error in
            XCTAssertEqual(error as? BlocktankRefundAddressError, .invalidCache)
        }
    }

    func testEstimatesNeverResolveRefundAddress() async {
        let refundProvider = StubRefundProvider(result: .success("refund"))
        var estimateCount = 0
        let viewModel = makeViewModel(refundProvider: refundProvider, estimate: { _, _, _ in
            estimateCount += 1
            throw StubError.estimate
        })

        for _ in 0 ..< 8 {
            await XCTAssertThrowsErrorAsync {
                try await viewModel.estimateOrderFee(clientBalance: 1, lspBalance: 2)
            }
        }

        XCTAssertEqual(refundProvider.callCount, 0)
        XCTAssertEqual(estimateCount, 8)
    }

    func testCreateOrderSubmitsResolvedRefundAddress() async {
        let refundProvider = StubRefundProvider(result: .success("refund-address"))
        var submittedOptions: CreateOrderOptions?
        let viewModel = makeViewModel(refundProvider: refundProvider, submit: { _, _, options in
            submittedOptions = options
            throw StubError.submit
        })

        await XCTAssertThrowsErrorAsync {
            try await viewModel.createOrder(clientBalance: 1, lspBalance: 2)
        }

        XCTAssertEqual(refundProvider.callCount, 1)
        XCTAssertEqual(submittedOptions?.refundOnchainAddress, "refund-address")
    }

    func testRefundResolutionFailureBlocksSubmission() async {
        let refundProvider = StubRefundProvider(result: .failure(StubError.lookup))
        var submitCount = 0
        let viewModel = makeViewModel(refundProvider: refundProvider, submit: { _, _, _ in
            submitCount += 1
            throw StubError.submit
        })

        await XCTAssertThrowsErrorAsync {
            try await viewModel.createOrder(clientBalance: 1, lspBalance: 2)
        }

        XCTAssertEqual(submitCount, 0)
    }

    func testMissingNodeBlocksResolutionAndSubmission() async {
        let refundProvider = StubRefundProvider(result: .success("refund"))
        var submitCount = 0
        let orderClient = BlocktankOrderClient(
            nodeId: { nil },
            sign: { _ in "signature" },
            submit: { _, _, _ in
                submitCount += 1
                throw StubError.submit
            },
            estimate: { _, _, _ in throw StubError.estimate }
        )
        let viewModel = BlocktankViewModel(
            orderClient: orderClient,
            refundAddressProvider: refundProvider,
            startPolling: false
        )

        await XCTAssertThrowsErrorAsync {
            try await viewModel.createOrder(clientBalance: 1, lspBalance: 2)
        }

        XCTAssertEqual(refundProvider.callCount, 0)
        XCTAssertEqual(submitCount, 0)
    }

    func testCancellationBeforeResolutionBlocksAllocationAndSubmission() async {
        let refundProvider = StubRefundProvider(result: .success("refund"))
        var submitCount = 0
        let viewModel = makeViewModel(refundProvider: refundProvider, submit: { _, _, _ in
            submitCount += 1
            throw StubError.submit
        })

        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await viewModel.createOrder(clientBalance: 1, lspBalance: 2)
        }

        await XCTAssertThrowsErrorAsync({ try await task.value }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(refundProvider.callCount, 0)
        XCTAssertEqual(submitCount, 0)
    }

    func testCancelledWaiterDoesNotSubmitWhileOtherWaiterCompletesResolution() async {
        let state = State()
        let provider = makeProvider(state: state, allocationDelayNanoseconds: 100_000_000)
        var submitCount = 0
        let viewModel = makeViewModel(refundProvider: provider, submit: { _, _, _ in
            submitCount += 1
            throw StubError.submit
        })

        let cancelled = Task { @MainActor in
            try await viewModel.createOrder(clientBalance: 1, lspBalance: 2)
        }
        await Task.yield()
        let active = Task { @MainActor in
            try await viewModel.createOrder(clientBalance: 1, lspBalance: 2)
        }
        cancelled.cancel()

        await XCTAssertThrowsErrorAsync({ try await cancelled.value }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        await XCTAssertThrowsErrorAsync({ try await active.value }) { error in
            XCTAssertTrue(error is StubError)
        }
        XCTAssertEqual(state.allocationCount, 1)
        XCTAssertEqual(submitCount, 1)
    }

    private func makeViewModel(
        refundProvider: any BlocktankRefundAddressProviding,
        submit: @escaping BlocktankOrderClient.Submit = { _, _, _ in throw StubError.submit },
        estimate: @escaping BlocktankOrderClient.Estimate = { _, _, _ in throw StubError.estimate }
    ) -> BlocktankViewModel {
        let orderClient = BlocktankOrderClient(
            nodeId: { "node-id" },
            sign: { _ in "signature" },
            submit: submit,
            estimate: estimate
        )
        return BlocktankViewModel(
            orderClient: orderClient,
            refundAddressProvider: refundProvider,
            startPolling: false
        )
    }

    private func XCTAssertThrowsErrorAsync(
        _ expression: () async throws -> some Any,
        _ errorHandler: (Error) -> Void = { _ in },
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected error", file: file, line: line)
        } catch {
            errorHandler(error)
        }
    }
}
