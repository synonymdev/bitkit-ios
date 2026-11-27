@testable import Bitkit
import XCTest

@MainActor
final class WalletViewModelRecoveryServersTests: XCTestCase {
    func testRecoveryRestartsWithTheSavedServers() throws {
        let suiteName = "WalletViewModelRecoveryServersTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let lightningService = Bitkit.LightningService.shared
        let previousSavedServerUrls = lightningService.savedServerUrls
        defer { lightningService.savedServerUrls = previousSavedServerUrls }

        let electrumConfigService = Bitkit.ElectrumConfigService(defaults: defaults)
        let rgsConfigService = Bitkit.RgsConfigService(defaults: defaults)
        _ = WalletViewModel(
            lightningService: lightningService,
            electrumConfigService: electrumConfigService,
            rgsConfigService: rgsConfigService,
            transferService: TransferService(lightningService: lightningService),
            sheetViewModel: SheetViewModel(),
            feeEstimatesManager: FeeEstimatesManager()
        )

        let custom = Bitkit.ElectrumServer(host: "custom.example.com", port: 50002, protocolType: .ssl)
        electrumConfigService.saveServerConfig(custom)
        rgsConfigService.saveServerUrl("https://rgs.example.com/snapshot")

        let servers = lightningService.savedServerUrls()
        XCTAssertEqual(servers.electrum, custom.fullUrl)
        XCTAssertEqual(servers.rgs, "https://rgs.example.com/snapshot")
    }
}
