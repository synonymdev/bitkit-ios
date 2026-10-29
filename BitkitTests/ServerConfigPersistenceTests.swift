@testable import Bitkit
import XCTest

final class ServerConfigPersistenceTests: XCTestCase {
    func testElectrumConfigReflectsWipeAndSubsequentWalletSettings() throws {
        let suiteName = "ServerConfigPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let writer = ElectrumConfigService(defaults: defaults)
        let reader = ElectrumConfigService(defaults: defaults)
        let oldServer = ElectrumServer(host: "old.example.com", port: 50001, protocolType: .tcp)

        writer.saveServerConfig(oldServer)
        XCTAssertEqual(reader.getCurrentServer(), oldServer)

        defaults.removePersistentDomain(forName: suiteName)

        XCTAssertNil(writer.getStoredServer())
        XCTAssertNil(reader.getStoredServer())
        XCTAssertEqual(reader.getCurrentServer(), reader.getDefaultServer())
        XCTAssertTrue((defaults.persistentDomain(forName: suiteName) ?? [:]).isEmpty)

        let newServer = ElectrumServer(host: "new.example.com", port: 50002, protocolType: .ssl)
        writer.saveServerConfig(newServer)
        XCTAssertEqual(reader.getCurrentServer(), newServer)
    }

    func testRgsConfigReflectsWipeAndSubsequentWalletSettings() throws {
        let suiteName = "ServerConfigPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let writer = RgsConfigService(defaults: defaults)
        let reader = RgsConfigService(defaults: defaults)

        writer.saveServerUrl("https://old.example.com")
        XCTAssertEqual(reader.getCurrentServerUrl(), "https://old.example.com")

        defaults.removePersistentDomain(forName: suiteName)

        XCTAssertEqual(writer.getCurrentServerUrl(), writer.getDefaultServerUrl())
        XCTAssertEqual(reader.getCurrentServerUrl(), reader.getDefaultServerUrl())
        XCTAssertTrue((defaults.persistentDomain(forName: suiteName) ?? [:]).isEmpty)

        writer.saveServerUrl("https://new.example.com")
        XCTAssertEqual(reader.getCurrentServerUrl(), "https://new.example.com")
    }
}
