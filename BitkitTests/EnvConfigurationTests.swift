@testable import Bitkit
import XCTest

final class EnvConfigurationTests: XCTestCase {
    func testRuntimeOverridesAreLimitedToDevelopmentBuilds() {
        let keys = ["USDT_RPC_URL", "E2E"]
        let original = keys.map { ProcessInfo.processInfo.environment[$0] }
        defer {
            for (key, value) in zip(keys, original) {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
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

    #if DEBUG || E2E_BUILD
        func testBackupFixtureRequiresAnExplicitValidPair() throws {
            let vss = "http://localhost:18657/vss"
            let auth = "http://localhost:18655/auth"
            XCTAssertNil(try Env.BackupTestEndpoints.resolve(enabled: false, vss: vss, auth: nil))
            XCTAssertNil(try Env.BackupTestEndpoints.resolve(enabled: true, vss: nil, auth: " "))
            XCTAssertEqual(
                try Env.BackupTestEndpoints.resolve(enabled: true, vss: " \(vss) ", auth: auth),
                Env.BackupTestEndpoints(vss: vss, auth: auth)
            )
            for invalid in [nil, "", "https://example.com/auth", "http://127.0.0.1:18655/auth",
                            "http://localhost/auth", "http://user@localhost:18655/auth",
                            "http://localhost:18655/auth?token=x", "http://localhost:18655/auth#fragment"]
            {
                XCTAssertThrowsError(try Env.BackupTestEndpoints.resolve(enabled: true, vss: vss, auth: invalid))
                XCTAssertThrowsError(try Env.BackupTestEndpoints.resolve(enabled: true, vss: invalid, auth: auth))
            }
        }

        func testBackupFixtureOverridesRequireExplicitEnablement() {
            let keys = ["E2E", "E2E_VSS_SERVER_URL", "E2E_LNURL_AUTH_SERVER_URL"]
            let original = keys.map { ProcessInfo.processInfo.environment[$0] }
            defer {
                for (key, value) in zip(keys, original) {
                    if let value {
                        setenv(key, value, 1)
                    } else {
                        unsetenv(key)
                    }
                }
            }
            setenv("E2E_VSS_SERVER_URL", "http://localhost:18657/vss", 1)
            setenv("E2E_LNURL_AUTH_SERVER_URL", "http://localhost:18655/auth", 1)
            #if !E2E_BUILD
                setenv("E2E", "false", 1)
                XCTAssertFalse(Env.vssServerUrl.contains("localhost"))
                XCTAssertFalse(Env.lnurlAuthServerUrl.contains("localhost"))
            #endif
            setenv("E2E", "true", 1)
            XCTAssertEqual(Env.vssServerUrl, "http://localhost:18657/vss")
            XCTAssertEqual(Env.lnurlAuthServerUrl, "http://localhost:18655/auth")
        }
    #endif
}
