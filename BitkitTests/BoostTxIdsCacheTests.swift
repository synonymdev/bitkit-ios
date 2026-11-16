@testable import Bitkit
import os
import XCTest

final class BoostTxIdsCacheTests: XCTestCase {
    func testConcurrentColdReadsShareOneRebuild() async throws {
        let cache = BoostTxIdsCache()
        let started = expectation(description: "rebuild started")
        let loader = makeLoader(started: started)
        let tasks = try (0 ..< 32).map { _ in
            try loadingTask(cache.read(walletId: "bitkit") { await loader.load() })
        }

        await fulfillment(of: [started], timeout: 5)
        await loader.finish(call: 1, value: ["original"])
        for result in await results(of: tasks) {
            assertLoaded(result, equals: ["original"])
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
        let loader = makeLoader(started: started)
        let tasks = try (0 ..< 16).map { _ in
            try loadingTask(cache.read(walletId: "bitkit") { await loader.load() })
        }
        await fulfillment(of: [started], timeout: 5)
        await loader.finish(call: 1, value: nil)
        for result in await results(of: tasks) {
            assertLoaded(result, equals: [])
        }
        let calls = await loader.calls
        XCTAssertEqual(calls, 1)

        let retried = await cache.get(walletId: "bitkit") { ["retried"] }
        XCTAssertEqual(retried, ["retried"])
    }

    func testFailedWarmRefreshKeepsLastSuccessfulValueForAllWaiters() async throws {
        let cache = BoostTxIdsCache()
        _ = await cache.get(walletId: "bitkit") { ["original"] }
        let started = expectation(description: "refresh started")
        let loader = makeLoader(started: started)
        let refresh = try loadingTask(cache.read(walletId: "bitkit", forceRefresh: true) { await loader.load() })
        let joined = try (0 ..< 16).map { _ in
            try loadingTask(cache.read(walletId: "bitkit") { XCTFail("Readers must share the refresh"); return nil })
        }
        await fulfillment(of: [started], timeout: 5)
        await loader.finish(call: 1, value: nil)
        await assertLoaded(result(of: refresh), equals: ["original"])
        for result in await results(of: joined) {
            assertLoaded(result, equals: ["original"])
        }

        let cached = await cache.get(walletId: "bitkit") { XCTFail("Failed refresh must retain the warm cache"); return nil }
        XCTAssertEqual(cached, ["original"])
        let calls = await loader.calls
        XCTAssertEqual(calls, 1)

        let retried = await cache.get(walletId: "bitkit", forceRefresh: true) { ["new"] }
        XCTAssertEqual(retried, ["new"])
    }

    func testSuccessfulWarmRefreshReplacesOldValueIncludingEmptyResult() async {
        let cache = BoostTxIdsCache()
        _ = await cache.get(walletId: "bitkit") { ["old"] }
        let replaced = await cache.get(walletId: "bitkit", forceRefresh: true) { ["new"] }
        XCTAssertEqual(replaced, ["new"])
        let emptied = await cache.get(walletId: "bitkit", forceRefresh: true) { [] }
        XCTAssertTrue(emptied.isEmpty)
        let cached = await cache.get(walletId: "bitkit") { XCTFail("An empty successful refresh must remain warm"); return nil }
        XCTAssertTrue(cached.isEmpty)
    }

    func testFailedEmptyWarmRefreshStaysWarm() async {
        let cache = BoostTxIdsCache()
        _ = await cache.get(walletId: "bitkit") { [] }
        let failed = await cache.get(walletId: "bitkit", forceRefresh: true) { nil }
        XCTAssertTrue(failed.isEmpty)
        let cached = await cache.get(walletId: "bitkit") { XCTFail("An empty previous value must not become cold on failure"); return nil }
        XCTAssertTrue(cached.isEmpty)
    }

    func testWritesDuringWarmRefreshSurviveSuccessAndFailure() async throws {
        for succeeds in [true, false] {
            let cache = BoostTxIdsCache()
            _ = await cache.get(walletId: "bitkit") { ["old"] }
            let started = expectation(description: "refresh started")
            let loader = makeLoader(started: started)
            let refresh = try loadingTask(cache.read(walletId: "bitkit", forceRefresh: true) { await loader.load() })
            await fulfillment(of: [started], timeout: 5)
            cache.merge(["new-boost"], walletId: "bitkit")
            await loader.finish(call: 1, value: succeeds ? ["snapshot"] : nil)
            let expected: Set<String> = [succeeds ? "snapshot" : "old", "new-boost"]
            await assertLoaded(result(of: refresh), equals: expected)
            let cached = await cache.get(walletId: "bitkit") { XCTFail("Completed refresh should be warm"); return nil }
            XCTAssertEqual(cached, expected)
        }
    }

    func testInvalidationDuringWarmRefreshCannotRestoreFallback() async {
        for wipe in [true, false] {
            let cache = BoostTxIdsCache()
            _ = await cache.get(walletId: "bitkit") { ["old"] }
            _ = await cache.get(walletId: "hardware") { ["hardware"] }
            let started = expectation(description: "both loads started")
            started.expectedFulfillmentCount = 2
            let firstStarted = expectation(description: "refresh started")
            let loader = makeLoader(started: started, firstStarted: firstStarted)
            let refresh = Task { await cache.get(walletId: "bitkit", forceRefresh: true) { await loader.load() } }
            await fulfillment(of: [firstStarted], timeout: 5)
            if wipe {
                cache.invalidateAll()
            } else {
                cache.invalidate(walletId: "bitkit")
            }
            await loader.finish(call: 1, value: nil)
            await fulfillment(of: [started], timeout: 5)
            await loader.finish(call: 2, value: nil)
            let result = await boundedValue { await refresh.value }
            XCTAssertEqual(result, [])
            let fresh = await cache.get(walletId: "bitkit") { ["fresh"] }
            XCTAssertEqual(fresh, ["fresh"], "Strict invalidation must not retain the pre-invalidation value")
            let other = await cache.get(walletId: "hardware") { ["after-wipe"] }
            XCTAssertEqual(other, wipe ? ["after-wipe"] : ["hardware"])
        }
    }

    func testNewerRefreshSupersedesOlderFlightWithoutLosingFallback() async throws {
        let cache = BoostTxIdsCache()
        _ = await cache.get(walletId: "bitkit") { ["old"] }
        let firstStarted = expectation(description: "first refresh started")
        let secondStarted = expectation(description: "second refresh started")
        let firstLoader = makeLoader(started: firstStarted)
        let secondLoader = makeLoader(started: secondStarted)
        let first = try loadingTask(cache.read(walletId: "bitkit", forceRefresh: true) { await firstLoader.load() })
        await fulfillment(of: [firstStarted], timeout: 5)
        cache.merge(["added"], walletId: "bitkit")
        let second = try loadingTask(cache.read(walletId: "bitkit", forceRefresh: true) { await secondLoader.load() })
        await fulfillment(of: [secondStarted], timeout: 5)
        await secondLoader.finish(call: 1, value: nil)
        await assertLoaded(result(of: second), equals: ["old", "added"])
        await firstLoader.finish(call: 1, value: ["stale"])
        guard case .invalidated? = await result(of: first) else { return XCTFail("Superseded refresh must be discarded") }
        let cached = await cache.get(walletId: "bitkit") { XCTFail("Late completion must not remove the retained value"); return nil }
        XCTAssertEqual(cached, ["old", "added"])
    }

    func testWalletsRebuildIndependently() async throws {
        let cache = BoostTxIdsCache()
        let firstStarted = expectation(description: "first wallet rebuild started")
        let secondStarted = expectation(description: "second wallet rebuild started")
        let firstLoader = makeLoader(started: firstStarted)
        let secondLoader = makeLoader(started: secondStarted)
        let first = try loadingTask(cache.read(walletId: "bitkit") { await firstLoader.load() })
        let second = try loadingTask(cache.read(walletId: "hardware") { await secondLoader.load() })
        await fulfillment(of: [firstStarted, secondStarted], timeout: 5)

        await secondLoader.finish(call: 1, value: ["hardware-tx"])
        await assertLoaded(result(of: second), equals: ["hardware-tx"])
        await firstLoader.finish(call: 1, value: ["bitkit-tx"])
        await assertLoaded(result(of: first), equals: ["bitkit-tx"])
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
        let loader = makeLoader(started: started)
        let task = try loadingTask(cache.read(walletId: "bitkit") { await loader.load() })
        await fulfillment(of: [started], timeout: 5)
        cache.merge(["new-boost"], walletId: "bitkit")
        await loader.finish(call: 1, value: ["existing-boost"])
        await assertLoaded(result(of: task), equals: ["existing-boost", "new-boost"])

        cache.merge(["later-boost"], walletId: "bitkit")
        let cached = await cache.get(walletId: "bitkit") { XCTFail("Cache should be warm"); return nil }
        XCTAssertEqual(cached, ["existing-boost", "new-boost", "later-boost"])
    }

    func testInvalidatedRebuildCannotOverwriteNewerCacheOrClearItsFlight() async throws {
        let cache = BoostTxIdsCache()
        let oldStarted = expectation(description: "old rebuild started")
        let newStarted = expectation(description: "new rebuild started")
        let oldLoader = makeLoader(started: oldStarted)
        let newLoader = makeLoader(started: newStarted)
        let old = try loadingTask(cache.read(walletId: "bitkit") { await oldLoader.load() })
        await fulfillment(of: [oldStarted], timeout: 5)
        cache.invalidate(walletId: "bitkit")
        let new = try loadingTask(cache.read(walletId: "bitkit") { await newLoader.load() })
        await fulfillment(of: [newStarted], timeout: 5)

        await oldLoader.finish(call: 1, value: ["stale"])
        guard case .invalidated? = await result(of: old) else { return XCTFail("Old rebuild must be discarded") }
        let joined = try loadingTask(cache.read(walletId: "bitkit") { XCTFail("New rebuild must remain shared"); return nil })
        await newLoader.finish(call: 1, value: ["fresh"])
        await assertLoaded(result(of: new), equals: ["fresh"])
        await assertLoaded(result(of: joined), equals: ["fresh"])

        let cached = await cache.get(walletId: "bitkit") { XCTFail("Cache should be warm"); return nil }
        XCTAssertEqual(cached, ["fresh"])
    }

    func testGetRetriesWhenItsRebuildIsInvalidated() async {
        let cache = BoostTxIdsCache()
        let started = expectation(description: "rebuild started")
        started.expectedFulfillmentCount = 2
        let firstStarted = expectation(description: "first rebuild started")
        let loader = makeLoader(started: started, firstStarted: firstStarted)
        let reader = Task { await cache.get(walletId: "bitkit") { await loader.load() } }
        await fulfillment(of: [firstStarted], timeout: 5)
        cache.invalidate(walletId: "bitkit")
        await loader.finish(call: 1, value: ["stale"])
        await fulfillment(of: [started], timeout: 5)
        await loader.finish(call: 2, value: ["fresh"])
        let value = await boundedValue { await reader.value }
        XCTAssertEqual(value, ["fresh"])
    }

    func testLateInvalidatedFailureCannotClearNewCache() async throws {
        let cache = BoostTxIdsCache()
        let started = expectation(description: "old rebuild started")
        let loader = makeLoader(started: started)
        let old = try loadingTask(cache.read(walletId: "bitkit") { await loader.load() })
        await fulfillment(of: [started], timeout: 5)
        cache.invalidate(walletId: "bitkit")
        let fresh = await cache.get(walletId: "bitkit") { ["fresh"] }
        XCTAssertEqual(fresh, ["fresh"])

        await loader.finish(call: 1, value: nil)
        guard case .invalidated? = await result(of: old) else { return XCTFail("Old failure must be discarded") }
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
        let loader = makeLoader(started: started)
        let old = try loadingTask(cache.read(walletId: "loading") { await loader.load() })
        await fulfillment(of: [started], timeout: 5)
        cache.invalidateAll()
        await loader.finish(call: 1, value: ["old-loading"])
        guard case .invalidated? = await result(of: old) else { return XCTFail("Wipe must discard in-flight rebuilds") }

        let warm = await cache.get(walletId: "warm") { [] }
        let loading = await cache.get(walletId: "loading") { [] }
        XCTAssertTrue(warm.isEmpty)
        XCTAssertTrue(loading.isEmpty)
    }

    private func loadingTask(_ read: BoostTxIdsCache.Read) throws -> Task<BoostTxIdsCache.LoadResult, Never> {
        guard case let .loading(task) = read else { throw TestError.unexpectedCachedValue }
        return task
    }

    /// Teardown releases loads a test never finished, so a regression that starts extra loads fails instead of hanging.
    private func makeLoader(started: XCTestExpectation, firstStarted: XCTestExpectation? = nil) -> ControlledBoostCacheLoader {
        let loader = ControlledBoostCacheLoader(started: started, firstStarted: firstStarted)
        addTeardownBlock { await loader.releaseAll() }
        return loader
    }

    private func result(
        of task: Task<BoostTxIdsCache.LoadResult, Never>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> BoostTxIdsCache.LoadResult? {
        await boundedValue(file: file, line: line) { await task.value }
    }

    private func results(
        of tasks: [Task<BoostTxIdsCache.LoadResult, Never>],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> [BoostTxIdsCache.LoadResult] {
        let results = await boundedValue(file: file, line: line) {
            var results: [BoostTxIdsCache.LoadResult] = []
            for task in tasks {
                await results.append(task.value)
            }
            return results
        }
        return results ?? []
    }

    /// Waits for `operation` without waiting on it past `timeout`: a stalled load is reported as a failure.
    private func boundedValue<Value: Sendable>(
        timeout: Duration = .seconds(5),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        let value: Value? = await withCheckedContinuation { continuation in
            let resumeOnce = ResumeOnce(continuation)
            let timer = Task {
                try? await Task.sleep(for: timeout)
                resumeOnce.resume(nil)
            }
            Task {
                await resumeOnce.resume(operation())
                timer.cancel()
            }
        }
        if value == nil {
            XCTFail("Timed out after \(timeout) waiting for a boost cache load", file: file, line: line)
        }
        return value
    }

    private func assertLoaded(
        _ result: BoostTxIdsCache.LoadResult?,
        equals expected: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let result else { return }
        guard case let .loaded(value) = result else { return XCTFail("Expected a completed rebuild", file: file, line: line) }
        XCTAssertEqual(value, expected, file: file, line: line)
    }

    private enum TestError: Error {
        case unexpectedCachedValue
    }
}

private final class ResumeOnce<Value: Sendable>: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Value?, Never>?>

    init(_ continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = OSAllocatedUnfairLock(initialState: continuation)
    }

    func resume(_ value: Value?) {
        let pending = continuation.withLock { continuation in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

private actor ControlledBoostCacheLoader {
    private let started: XCTestExpectation
    private let firstStarted: XCTestExpectation?
    private var continuations: [Int: CheckedContinuation<Set<String>?, Never>] = [:]
    private var isReleased = false
    private(set) var calls = 0

    init(started: XCTestExpectation, firstStarted: XCTestExpectation? = nil) {
        // Extra loads are a regression for the call-count assertions to report, not an XCTest API violation.
        started.assertForOverFulfill = false
        firstStarted?.assertForOverFulfill = false
        self.started = started
        self.firstStarted = firstStarted
    }

    func load() async -> Set<String>? {
        calls += 1
        guard !isReleased else { return nil }
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

    func releaseAll() {
        isReleased = true
        for continuation in continuations.values {
            continuation.resume(returning: nil)
        }
        continuations.removeAll()
    }
}
