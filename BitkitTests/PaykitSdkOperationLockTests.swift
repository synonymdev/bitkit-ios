@testable import Bitkit
import Paykit
import XCTest

final class PaykitSdkOperationLockTests: XCTestCase {
    private actor Recorder {
        private(set) var events: [String] = []

        func record(_ event: String) {
            events.append(event)
        }
    }

    func testPublicCapabilityReadDoesNotWaitForSerializedSdkWork() async throws {
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let started = expectation(description: "Serialized work started")
        let read = expectation(description: "Public capability read completes while serialized work is suspended")
        let sdk = PublicReadSdk(noPointer: .init())
        sdk.lockedRead = {
            started.fulfill()
            for await _ in gate {}
        }
        let service = PaykitSdkService(sdkFactory: { sdk })
        let holder = Task { try await service.resolveContactProfile(publicKey: "peer", allowPubkyProfileFallback: false) }
        await fulfillment(of: [started], timeout: 2)

        let lookup = Task {
            let result = try await service.canReceivePaymentRequests(publicKey: "peer")
            XCTAssertFalse(result)
            read.fulfill()
        }
        await fulfillment(of: [read], timeout: 0.5)
        release.finish()
        _ = try await holder.value
        try await lookup.value
    }

    func testSlowPublicCapabilityReadDoesNotHoldSerializedSdkQueue() async throws {
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let started = expectation(description: "Public capability read started")
        let completed = expectation(description: "Serialized work completes while public read is suspended")
        let sdk = PublicReadSdk(noPointer: .init())
        sdk.publicRead = {
            started.fulfill()
            for await _ in gate {}
        }
        let service = PaykitSdkService(sdkFactory: { sdk })
        let lookup = Task { try await service.canReceivePaymentRequests(publicKey: "peer") }
        await fulfillment(of: [started], timeout: 2)

        let work = Task {
            _ = try await service.resolveContactProfile(publicKey: "peer", allowPubkyProfileFallback: false)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 0.5)
        release.finish()
        try await work.value
        _ = try await lookup.value
    }

    func testPublicReadRejectsResultAfterWalletWipe() async throws {
        let lock = PaykitSdkOperationLock()
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let started = expectation(description: "Public read started")
        let lookup = Task {
            try await lock.withPublicRead {
                started.fulfill()
                for await _ in gate {}
                return true
            }
        }
        await fulfillment(of: [started], timeout: 2)
        try await lock.withWalletWipe {
            do {
                try await lock.withPublicRead { XCTFail("Public reads must not start during a wipe") }
                XCTFail("Expected wipe rejection")
            } catch let PaykitError.Storage(code, _) {
                XCTAssertEqual(code, "wallet_wipe_in_progress")
            }
        }
        release.finish()
        do {
            _ = try await lookup.value
            XCTFail("Expected result from the previous wallet generation to be rejected")
        } catch let PaykitError.Storage(code, _) {
            XCTAssertEqual(code, "wallet_wipe_in_progress")
        }
    }

    func testPublicReadDiscardsCancelledResult() async throws {
        let lock = PaykitSdkOperationLock()
        let lookup = Task {
            try await lock.withPublicRead {
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            }
        }
        do {
            _ = try await lookup.value
            XCTFail("Expected cancelled result to be rejected")
        } catch is CancellationError {}
        try await lock.withLock {}
    }

    func testAlreadyCancelledPublicReadDoesNotStart() async throws {
        let lock = PaykitSdkOperationLock()
        let lookup = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await lock.withPublicRead { XCTFail("Cancelled public read must not start") }
        }
        do {
            try await lookup.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    func testWipeDrainsActiveWorkRejectsQueuedWorkAndAllowsCleanupAndFreshWork() async throws {
        let lock = PaykitSdkOperationLock()
        let recorder = Recorder()
        let (activeGate, releaseActive) = AsyncStream<Void>.makeStream()
        let (activeStarted, startActive) = AsyncStream<Void>.makeStream()
        let (wipeGate, releaseWipe) = AsyncStream<Void>.makeStream()
        let (wipeStarted, startWipe) = AsyncStream<Void>.makeStream()
        let active = Task {
            try await lock.withLock {
                await recorder.record("active")
                startActive.yield()
                for await _ in activeGate {
                    break
                }
            }
        }
        for await _ in activeStarted {
            break
        }
        let queued = Task {
            try await lock.withLock { await recorder.record("stale") }
        }
        try await Task.sleep(for: .milliseconds(50))
        let wipe = Task {
            try await lock.withWalletWipe {
                try await lock.withLock { await recorder.record("cleanup") }
                startWipe.yield()
                for await _ in wipeGate {
                    break
                }
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        do {
            try await lock.withLock { await recorder.record("poll") }
            XCTFail("Expected work during wipe to be rejected")
        } catch let PaykitError.Storage(code, _) {
            XCTAssertEqual(code, "wallet_wipe_in_progress")
        }
        releaseActive.yield()
        for await _ in wipeStarted {
            break
        }
        do {
            try await queued.value
            XCTFail("Expected queued work from the old wallet to be rejected")
        } catch let PaykitError.Storage(code, _) {
            XCTAssertEqual(code, "wallet_wipe_in_progress")
        }
        releaseWipe.yield()
        try await active.value
        try await wipe.value
        try await lock.withLock { await recorder.record("fresh") }
        let events = await recorder.events
        XCTAssertEqual(events, ["active", "cleanup", "fresh"])
    }

    func testCancelledWipeDrainsActiveWorkWithoutRunningCleanup() async throws {
        let lock = PaykitSdkOperationLock()
        let (activeGate, releaseActive) = AsyncStream<Void>.makeStream()
        let (activeStarted, startActive) = AsyncStream<Void>.makeStream()
        let active = Task {
            try await lock.withLock {
                startActive.yield()
                for await _ in activeGate {
                    break
                }
            }
        }
        for await _ in activeStarted {
            break
        }
        let wipe = Task {
            try await lock.withWalletWipe { XCTFail("Cancelled wipe ran cleanup") }
        }
        try await Task.sleep(for: .milliseconds(50))
        wipe.cancel()
        releaseActive.yield()
        try await active.value
        do {
            try await wipe.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        try await lock.withLock {}
    }

    func testFailedWipeReleasesAdmission() async throws {
        let lock = PaykitSdkOperationLock()
        do {
            try await lock.withWalletWipe { throw KeychainError.failedToDelete }
            XCTFail("Expected cleanup failure")
        } catch KeychainError.failedToDelete {}
        try await lock.withLock {}
    }
}

private final class PublicReadSdk: PaykitSdk, @unchecked Sendable {
    var publicRead: () async -> Void = {}
    var lockedRead: () async -> Void = {}

    override func paykitAppRegistry(publicKey _: String) async throws -> PaykitAppRegistry? {
        await publicRead()
        return nil
    }

    override func resolveProfile(publicKey _: String, allowPubkyProfileFallback _: Bool) async throws -> ProfileResolution? {
        await lockedRead()
        return nil
    }
}
