@testable import Bitkit
import XCTest

/// Wallets that stored a retired default Electrum server (from an older build or a SETTINGS backup) must fall back to
/// the current default, while servers the user chose stay as they are.
@MainActor
final class RetiredElectrumServerTests: XCTestCase {
    private let retiredFulcrum = ElectrumServer(host: "fulcrum.bitkit.blocktank.to", port: 8900, protocolType: .ssl)
    private let retiredIp = ElectrumServer(host: "35.187.18.233", port: 8900, protocolType: .ssl)
    private let custom = ElectrumServer(host: "electrum.example.com", port: 50002, protocolType: .ssl)

    private func makeService() throws -> (ElectrumConfigService, UserDefaults) {
        let suiteName = "RetiredElectrumServerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return (ElectrumConfigService(defaults: defaults), defaults)
    }

    // MARK: - ElectrumConfigService

    func testStoredRetiredDefaultsFallBackToCurrentDefault() throws {
        for retired in [retiredFulcrum, retiredIp] {
            let (service, defaults) = try makeService()
            service.saveServerConfig(retired)

            XCTAssertEqual(service.getCurrentServer(), service.getDefaultServer())
            XCTAssertNil(service.getStoredServer())
            XCTAssertNil(defaults.data(forKey: "electrumServer"), "the retired server is cleared, not just hidden")
        }
    }

    func testRetiredDefaultMatchIgnoresHostCase() throws {
        let (service, _) = try makeService()
        service.saveServerConfig(ElectrumServer(host: "Fulcrum.Bitkit.Blocktank.to", port: 8900, protocolType: .ssl))

        XCTAssertNil(service.getStoredServer())
    }

    func testRetiredHostOnAnotherPortIsKept() throws {
        let (service, _) = try makeService()
        let otherPort = ElectrumServer(host: "fulcrum.bitkit.blocktank.to", port: 50002, protocolType: .ssl)
        service.saveServerConfig(otherPort)

        XCTAssertEqual(service.getCurrentServer(), otherPort)
    }

    func testCustomServerIsKept() throws {
        let (service, _) = try makeService()
        service.saveServerConfig(custom)

        XCTAssertEqual(service.getCurrentServer(), custom)
        XCTAssertEqual(service.getCustomServerForBackup(), custom)
    }

    func testDefaultServerIsNotBackedUp() throws {
        let (service, _) = try makeService()
        XCTAssertNil(service.getCustomServerForBackup(), "nothing stored")

        service.saveServerConfig(service.getDefaultServer())
        XCTAssertNil(service.getCustomServerForBackup(), "stored value equal to the default")

        service.saveServerConfig(retiredFulcrum)
        XCTAssertNil(service.getCustomServerForBackup(), "retired default")
    }

    // MARK: - SETTINGS backup and restore

    func testBackupOmitsDefaultServerAndKeepsCustomServer() {
        snapshotAppDefaultsDomain()
        let settings = SettingsViewModel.shared
        settings.electrumConfigService.clearStoredServer()

        XCTAssertNil(settings.getSettingsDictionary()["electrumServer"])

        settings.electrumConfigService.saveServerConfig(custom)
        XCTAssertEqual(settings.getSettingsDictionary()["electrumServer"] as? String, custom.fullUrl)
    }

    func testRestoreOfRetiredDefaultUsesCurrentDefault() {
        snapshotAppDefaultsDomain()
        let settings = SettingsViewModel.shared
        let service = settings.electrumConfigService

        for url in ElectrumConfigService.retiredDefaultServerUrls {
            service.saveServerConfig(custom)
            settings.restoreSettingsDictionary(["electrumServer": url])

            XCTAssertNil(UserDefaults.standard.data(forKey: "electrumServer"), url)
            XCTAssertEqual(service.getCurrentServer(), service.getDefaultServer(), url)
            XCTAssertEqual(settings.electrumCurrentServer, service.getDefaultServer(), url)
        }
    }

    func testRestoreOfDefaultLeavesNoStoredServer() {
        snapshotAppDefaultsDomain()
        let settings = SettingsViewModel.shared
        let service = settings.electrumConfigService

        settings.restoreSettingsDictionary(["electrumServer": service.getDefaultServer().fullUrl])

        XCTAssertNil(UserDefaults.standard.data(forKey: "electrumServer"))
    }

    func testRestoreWithoutServerClearsStoredServer() {
        snapshotAppDefaultsDomain()
        let settings = SettingsViewModel.shared
        let service = settings.electrumConfigService
        service.saveServerConfig(custom)

        settings.restoreSettingsDictionary([:])

        XCTAssertEqual(service.getCurrentServer(), service.getDefaultServer())
    }

    func testRestoreOfCustomServerKeepsIt() {
        snapshotAppDefaultsDomain()
        let settings = SettingsViewModel.shared
        let service = settings.electrumConfigService

        settings.restoreSettingsDictionary(["electrumServer": custom.fullUrl])

        XCTAssertEqual(service.getCurrentServer(), custom)
    }
}
