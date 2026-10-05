@testable import Bitkit
import BitkitCore
import XCTest

final class JadeServiceTests: XCTestCase {
    /// `JadeService.finalizePsbt` shares its name with the core function it wraps. Called unqualified,
    /// it would call itself until the stack overflows instead of reaching core.
    func testFinalizePsbtReachesTheCoreFunctionInsteadOfRecursing() async {
        let sut = JadeService(transport: JadeTransport(driver: FakeBLEDriver()))

        do {
            _ = try await sut.finalizePsbt(originalPsbt: "not a psbt", signedPsbt: "not a psbt")
            XCTFail("core must reject an invalid psbt")
        } catch {
            XCTAssertTrue((error as? Bitkit.AppError)?.underlyingError is PsbtCompletionError, "error=\(error)")
        }
    }
}
