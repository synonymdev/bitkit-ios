@testable import Bitkit
import XCTest

final class EnvConfigurationTests: XCTestCase {
    func testRuntimeOverridesAreLimitedToDevelopmentBuilds() {
        let keys = ["USDT_RPC_URL", "E2E"]
        let original = keys.map { ProcessInfo.processInfo.environment[$0] }
        defer {
            for (key, value) in zip(keys, original) {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        setenv("USDT_RPC_URL", "https://override.invalid", 1)
        setenv("E2E", "true", 1)
        #if DEBUG || E2E_BUILD
            XCTAssertEqual(Env.usdtRpcUrl, "https://override.invalid")
            XCTAssertTrue(Env.isE2E)
        #else
            XCTAssertEqual(Env.usdtRpcUrl, Bundle.main.object(forInfoDictionaryKey: "USDT_RPC_URL") as? String)
            XCTAssertFalse(Env.isE2E)
        #endif
    }
}
