@testable import Bitkit
import XCTest

final class BoostTxIdsCacheTests: XCTestCase {
    func testConcurrentColdReadsShareOneRebuild() async throws {
        let cache = BoostTxIdsCache()
        let started = expectation(description: "rebuild started")
        let loader = ControlledBoostCacheLoader(started: started)
        let tasks = try (0 ..< 32).map { _ in
            try loadingTask(cache.read(walletId: "bitkit") { await loader.load() })
        }

        await fulfillment(of: [started], timeout: 5)
        await loader.finish(call: 1, value: ["original"])
        for task in tasks {
            await assertLoaded(task.value, equals: ["original"])
        }
        let calls = await loader.calls
        XCTAssertEqual(calls, 1)

        let cached = await cache.get(walletId: "bitkit") {
            XCTFail("A warm cache must not rebuild")
            return nil
        }
        XCTAssertEqual(cached, ["original"])
    }

    func testEmptyResultIsWarm() async {
        let cache = BoostTxIdsCache()
        let first = await cache.get(walletId: "bitkit") { [] }
        let second = await cache.get(walletId: "bitkit") {
            XCTFail("An empty result must stay cached")
            return nil
        }
        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
    }

    func testFailedSharedRebuildCanBeRetried() async throws {
        let cache = BoostTxIdsCache()
        let started = expectation(description: "rebuild started")
        let loader = ControlledBoostCacheLoader(started: started)
        let tasks = try (0 ..< 16).map { _ in
            try loadingTask(cache.read(walletId: "bitkit") { await loader.load() })
        }
        await fulfillment(of: [started], timeout: 5)
        await loader.finish(call: 1, value: nil)
        for task in tasks {
            await assertLoaded(task.value, equals: [])
        }
        let calls = await loader.calls
        XCTAssertEqual(calls, 1)

        let retried = await cache.get(walletId: "bitkit") { ["retried"] }
        XCTAssertEqual(retried, ["retried"])
    }

    func testWalletsRebuildIndependently() async throws {
        let cache = BoostTxIdsCache()
        let firstStarted = expectation(description: "first wallet rebuild started")
        let secondStarted = expectation(description: "second wallet rebuild started")
        let firstLoader = ControlledBoostCacheLoader(started: firstStarted)
        let secondLoader = ControlledBoostCacheLoader(started: secondStarted)
        let first = try loadingTask(cache.read(walletId: "bitkit") { await firstLoader.load() })
        let second = try loadingTask(cache.read(walletId: "hardware") { await secondLoader.load() })
        await fulfillment(of: [firstStarted, secondStarted], timeout: 5)

        await secondLoader.finish(call: 1, value: ["hardware-tx"])
        await assertLoaded(second.value, equals: ["hardware-tx"])
        await firstLoader.finish(call: 1, value: ["bitkit-tx"])
        await assertLoaded(first.value, equals: ["bitkit-tx"])
    }

    func testColdMergeDoesNotSeedPartialCache() async {
        let cache = BoostTxIdsCache()
        cache.merge(["one-row"], walletId: "bitkit")
        let value = await cache.get(walletId: "bitkit") { ["one-row", "another-row"] }
        XCTAssertEqual(value, ["one-row", "another-row"])
    }

    func testMergeDuringRebuildIsNotLost() async throws {
        let cache = BoostTxIdsCache()
        let started = expectation(description: "rebuild started")
        let loader = ControlledBoostCacheLoader(started: started)
        let task = try loadingTask(cache.read(walletId: "bitkit") { await loader.load() })
        await fulfillment(of: [started], timeout: 5)
        cache.merge(["new-boost"], walletId: "bitkit")
        await loader.finish(call: 1, value: ["existing-boost"])
        await assertLoaded(task.value, equals: ["existing-boost", "new-boost"])

        cache.merge(["later-boost"], walletId: "bitkit")
        let cached = await cache.get(walletId: "bitkit") { XCTFail("Cache should be warm"); return nil }
        XCTAssertEqual(cached, ["existing-boost", "new-boost", "later-boost"])
    }

    func testInvalidatedRebuildCannotOverwriteNewerCacheOrClearItsFlight() async throws {
        let cache = BoostTxIdsCache()
        let oldStarted = expectation(description: "old rebuild started")
        let newStarted = expectation(description: "new rebuild started")
        let oldLoader = ControlledBoostCacheLoader(started: oldStarted)
        let newLoader = ControlledBoostCacheLoader(started: newStarted)
        let old = try loadingTask(cache.read(walletId: "bitkit") { await oldLoader.load() })
        await fulfillment(of: [oldStarted], timeout: 5)
        cache.invalidate(walletId: "bitkit")
        let new = try loadingTask(cache.read(walletId: "bitkit") { await newLoader.load() })
        await fulfillment(of: [newStarted], timeout: 5)

        await oldLoader.finish(call: 1, value: ["stale"])
        guard case .invalidated = await old.value else { return XCTFail("Old rebuild must be discarded") }
        let joined = try loadingTask(cache.read(walletId: "bitkit") { XCTFail("New rebuild must remain shared"); return nil })
        await newLoader.finish(call: 1, value: ["fresh"])
        await assertLoaded(new.value, equals: ["fresh"])
        await assertLoaded(joined.value, equals: ["fresh"])

        let cached = await cache.get(walletId: "bitkit") { XCTFail("Cache should be warm"); return nil }
        XCTAssertEqual(cached, ["fresh"])
    }

    func testGetRetriesWhenItsRebuildIsInvalidated() async {
        let cache = BoostTxIdsCache()
        let started = expectation(description: "rebuild started")
        started.expectedFulfillmentCount = 2
        let firstStarted = expectation(description: "first rebuild started")
        let loader = ControlledBoostCacheLoader(started: started, firstStarted: firstStarted)
        let reader = Task { await cache.get(walletId: "bitkit") { await loader.load() } }
        await fulfillment(of: [firstStarted], timeout: 5)
        cache.invalidate(walletId: "bitkit")
        await loader.finish(call: 1, value: ["stale"])
        await fulfillment(of: [started], timeout: 5)
        await loader.finish(call: 2, value: ["fresh"])
        let value = await reader.value
        XCTAssertEqual(value, ["fresh"])
    }

    func testLateInvalidatedFailureCannotClearNewCache() async throws {
        let cache = BoostTxIdsCache()
        let started = expectation(description: "old rebuild started")
        let loader = ControlledBoostCacheLoader(started: started)
        let old = try loadingTask(cache.read(walletId: "bitkit") { await loader.load() })
        await fulfillment(of: [started], timeout: 5)
        cache.invalidate(walletId: "bitkit")
        let fresh = await cache.get(walletId: "bitkit") { ["fresh"] }
        XCTAssertEqual(fresh, ["fresh"])

        await loader.finish(call: 1, value: nil)
        guard case .invalidated = await old.value else { return XCTFail("Old failure must be discarded") }
        let cached = await cache.get(walletId: "bitkit") { XCTFail("Old failure must not clear the cache"); return nil }
        XCTAssertEqual(cached, ["fresh"])
    }

    func testInvalidatingOneWalletKeepsOtherWalletWarm() async {
        let cache = BoostTxIdsCache()
        _ = await cache.get(walletId: "bitkit") { ["bitkit-tx"] }
        _ = await cache.get(walletId: "hardware") { ["hardware-tx"] }
        cache.invalidate(walletId: "hardware")

        let bitkit = await cache.get(walletId: "bitkit") { XCTFail("Unrelated wallet must remain warm"); return nil }
        let hardware = await cache.get(walletId: "hardware") { [] }
        XCTAssertEqual(bitkit, ["bitkit-tx"])
        XCTAssertTrue(hardware.isEmpty)
    }

    func testInvalidateAllDiscardsWarmAndInFlightWallets() async throws {
        let cache = BoostTxIdsCache()
        _ = await cache.get(walletId: "warm") { ["old-warm"] }
        let started = expectation(description: "rebuild started")
        let loader = ControlledBoostCacheLoader(started: started)
        let old = try loadingTask(cache.read(walletId: "loading") { await loader.load() })
        await fulfillment(of: [started], timeout: 5)
        cache.invalidateAll()
        await loader.finish(call: 1, value: ["old-loading"])
        guard case .invalidated = await old.value else { return XCTFail("Wipe must discard in-flight rebuilds") }

        let warm = await cache.get(walletId: "warm") { [] }
        let loading = await cache.get(walletId: "loading") { [] }
        XCTAssertTrue(warm.isEmpty)
        XCTAssertTrue(loading.isEmpty)
    }

    private func loadingTask(_ read: BoostTxIdsCache.Read) throws -> Task<BoostTxIdsCache.LoadResult, Never> {
        guard case let .loading(task) = read else { throw TestError.unexpectedCachedValue }
        return task
    }

    private func assertLoaded(_ result: BoostTxIdsCache.LoadResult, equals expected: Set<String>, file: StaticString = #filePath,
                              line: UInt = #line)
    {
        guard case let .loaded(value) = result else { return XCTFail("Expected a completed rebuild", file: file, line: line) }
        XCTAssertEqual(value, expected, file: file, line: line)
    }

    private enum TestError: Error {
        case unexpectedCachedValue
    }
}

private actor ControlledBoostCacheLoader {
    private let started: XCTestExpectation
    private let firstStarted: XCTestExpectation?
    private var continuations: [Int: CheckedContinuation<Set<String>?, Never>] = [:]
    private(set) var calls = 0

    init(started: XCTestExpectation, firstStarted: XCTestExpectation? = nil) {
        self.started = started
        self.firstStarted = firstStarted
    }

    func load() async -> Set<String>? {
        calls += 1
        return await withCheckedContinuation {
            continuations[calls] = $0
            if calls == 1 {
                firstStarted?.fulfill()
            }
            started.fulfill()
        }
    }

    func finish(call: Int, value: Set<String>?) {
        guard let continuation = continuations.removeValue(forKey: call) else { return XCTFail("Missing rebuild '\(call)'") }
        continuation.resume(returning: value)
    }
}
