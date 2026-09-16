@testable import Bitkit
import Paykit
import XCTest

final class PubkyIdentityRepublishTests: XCTestCase {
    private let publicKey = "3rsduhcxpw74snwyct86m38c63j3pq8x4ycqikxg64roik8yw5xg"
    private let now = Date(timeIntervalSince1970: 1000)

    func testSuccessfulPublicationIsThrottledAndReusesBootstrap() async {
        let bootstrap = RepublishBootstrap(noPointer: .init())
        var factories = 0
        let service = PaykitSdkService { _, _ in
            factories += 1
            return bootstrap
        }

        await service.republishIdentityIfNeeded(publicKey: publicKey, now: now)
        await service.republishIdentityIfNeeded(publicKey: "pubky\(publicKey)", now: now.addingTimeInterval(1799))
        await service.republishIdentityIfNeeded(publicKey: publicKey, now: now.addingTimeInterval(1800))

        XCTAssertEqual(bootstrap.publicKeys, Array(repeating: "pubky\(publicKey)", count: 2))
        XCTAssertEqual(factories, 1)
    }

    func testMissingRecordAndFailuresRetryWithoutWaitingForSuccessInterval() async {
        for result in [Result<Bool, Error>.success(false), .failure(PubkyServiceError.profileNotFound)] {
            let bootstrap = RepublishBootstrap(noPointer: .init())
            bootstrap.operation = { _ in try result.get() }
            let service = PaykitSdkService { _, _ in bootstrap }

            await service.republishIdentityIfNeeded(publicKey: publicKey, now: now)
            await service.republishIdentityIfNeeded(publicKey: publicKey, now: now.addingTimeInterval(59))
            await service.republishIdentityIfNeeded(publicKey: publicKey, now: now.addingTimeInterval(60))

            XCTAssertEqual(bootstrap.publicKeys.count, 2)
        }
    }

    func testNewIdentityDoesNotInheritPreviousIdentityThrottle() async {
        let bootstrap = RepublishBootstrap(noPointer: .init())
        let service = PaykitSdkService { _, _ in bootstrap }
        let otherKey = String(publicKey.dropLast()) + "y"

        await service.republishIdentityIfNeeded(publicKey: publicKey, now: now)
        await service.republishIdentityIfNeeded(publicKey: otherKey, now: now)

        XCTAssertEqual(bootstrap.publicKeys, ["pubky\(publicKey)", "pubky\(otherKey)"])
    }

    func testConcurrentTriggersDoNotOverlapPublication() async {
        let started = expectation(description: "Publication started")
        let gate = AsyncStream<Void>.makeStream()
        let bootstrap = RepublishBootstrap(noPointer: .init())
        bootstrap.operation = { _ in
            started.fulfill()
            for await _ in gate.stream {
                break
            }
            return true
        }
        let service = PaykitSdkService { _, _ in bootstrap }
        let first = Task { await service.republishIdentityIfNeeded(publicKey: publicKey, now: now) }
        await fulfillment(of: [started], timeout: 1)

        await service.republishIdentityIfNeeded(publicKey: publicKey, now: now.addingTimeInterval(3600))
        XCTAssertEqual(bootstrap.publicKeys.count, 1)

        gate.continuation.finish()
        await first.value
    }

    func testSlowPublicationDoesNotHoldCallerOrOverlapRetry() async {
        let started = expectation(description: "Publication started")
        let returned = expectation(description: "Caller returned")
        let finished = expectation(description: "Publication finished")
        let gate = AsyncStream<Void>.makeStream()
        let work = Task {
            for await _ in gate.stream {}
            return true
        }
        let bootstrap = RepublishBootstrap(noPointer: .init())
        bootstrap.operation = { _ in
            started.fulfill()
            let result = await work.value
            finished.fulfill()
            return result
        }
        let service = PaykitSdkService { _, _ in bootstrap }
        let caller = Task {
            await service.republishIdentityIfNeeded(publicKey: publicKey, now: now, timeout: .milliseconds(20))
            returned.fulfill()
        }
        await fulfillment(of: [started, returned], timeout: 1)

        await service.republishIdentityIfNeeded(publicKey: publicKey, now: now.addingTimeInterval(3600))
        XCTAssertEqual(bootstrap.publicKeys.count, 1)

        gate.continuation.finish()
        await fulfillment(of: [finished], timeout: 1)
        await caller.value

        bootstrap.operation = { _ in true }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        repeat {
            await service.republishIdentityIfNeeded(publicKey: publicKey, now: now.addingTimeInterval(3600))
            if bootstrap.publicKeys.count == 2 { break }
            await Task.yield()
        } while ContinuousClock.now < deadline
        XCTAssertEqual(bootstrap.publicKeys.count, 2)
    }

    func testAuthRepublishesSigningIdentityBeforeApprovalEvenWhenPublicationFails() async throws {
        for kind in [Approval.ordinary, .companion] {
            for result in [Result<Bool, Error>.success(true), .failure(PubkyServiceError.profileNotFound)] {
                let bootstrap = RepublishBootstrap(noPointer: .init())
                let service = PaykitSdkService { _, _ in bootstrap }
                let expectedKey = try PubkyService.pubkyPublicKeyFromSecret(secretKeyHex: String(repeating: "01", count: 32))
                var approved = false
                bootstrap.operation = { _ in try result.get() }
                bootstrap.approval = {
                    XCTAssertEqual(bootstrap.publicKeys, [expectedKey])
                    approved = true
                }

                try await approve(kind, using: service)

                XCTAssertTrue(approved, "\(kind)")
                bootstrap.approval = {}
            }
        }
    }

    func testCancellationDuringPublicationStopsAllAuthApprovalPaths() async {
        for kind in Approval.allCases {
            let started = expectation(description: "Publication started for \(kind)")
            let gate = AsyncStream<Void>.makeStream()
            let bootstrap = RepublishBootstrap(noPointer: .init())
            let service = PaykitSdkService { _, _ in bootstrap }
            bootstrap.operation = { _ in
                started.fulfill()
                for await _ in gate.stream {}
                return true
            }
            bootstrap.approval = { XCTFail("Cancelled \(kind) approval must not be delivered") }
            let caller = Task { try await approve(kind, using: service) }
            await fulfillment(of: [started], timeout: 1)

            caller.cancel()
            do {
                try await caller.value
                XCTFail("Cancelled \(kind) approval must throw")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(kind): \(error)")
            }
            gate.continuation.finish()
        }
    }

    private enum Approval: CaseIterable {
        case ordinary, companion, ring
    }

    private func approve(_ kind: Approval, using service: PaykitSdkService) async throws {
        let secretKeyHex = String(repeating: "01", count: 32)
        let authUrl = "pubkyauth://signin_grant?caps=/pub/example/:rw&relay=https://httprelay.pubky.app/inbox/" +
            "&secret=e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3t7e3s" +
            "&cid=paykit.test&cpk=5jsjx1o6fzu6aeeo697r3i5rx15zq41kikcye8wtwdqm4nb4tryo"
        switch kind {
        case .ordinary:
            try await PubkyService.approveAuth(
                authUrl: authUrl, expectedCapabilities: "/pub/example/:rw", approvedClientID: "paykit.test",
                secretKeyHex: secretKeyHex, sdkService: service
            )
        case .companion:
            try await PubkyService.approveAuthWithCompanionClaim(
                authUrl: authUrl, approvedClientID: "paykit.test", unsignedPayload: Data(),
                secretKeyHex: secretKeyHex, sdkService: service
            )
        case .ring:
            try await PubkyService.approveRingAuth(authUrl: "invalid-auth-url", secretKeyHex: secretKeyHex, sdkService: service)
        }
    }
}

private final class RepublishBootstrap: PubkySessionBootstrap, @unchecked Sendable {
    var publicKeys: [String] = []
    var operation: (String) async throws -> Bool = { _ in true }
    var approval: () -> Void = {}

    override func republishIdentity(publicKey: String) async throws -> Bool {
        publicKeys.append(publicKey)
        return try await operation(publicKey)
    }

    override func approveAuth(authUrl _: String, expectedCapabilities _: String, localSecretKey _: PubkyLocalSecretKey) async throws {
        approval()
    }

    override func approveAuthWithCompanionClaim(
        authUrl _: String,
        expectedCapabilities _: String,
        localSecretKey _: PubkyLocalSecretKey,
        claim _: PubkyAuthCompanionClaim
    ) async throws {
        approval()
    }
}
