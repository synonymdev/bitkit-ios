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
}

private final class RepublishBootstrap: PubkySessionBootstrap, @unchecked Sendable {
    var publicKeys: [String] = []
    var operation: (String) async throws -> Bool = { _ in true }

    override func republishIdentity(publicKey: String) async throws -> Bool {
        publicKeys.append(publicKey)
        return try await operation(publicKey)
    }
}
