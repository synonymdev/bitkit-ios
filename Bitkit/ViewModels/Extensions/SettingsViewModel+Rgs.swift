import Foundation

// MARK: - RGS Server Management

extension SettingsViewModel {
    func loadRgsSettings() {
        // Load current RGS URL from storage
        let currentUrl = rgsConfigService.getCurrentServerUrl()
        rgsServerUrl = currentUrl
    }

    func resetRgsToDefault() async -> (success: Bool, url: String, errorMessage: String?) {
        let defaultUrl = rgsConfigService.getDefaultServerUrl()
        rgsServerUrl = defaultUrl

        return await connectToRgsServer()
    }

    func connectToRgsServer() async -> (success: Bool, url: String, errorMessage: String?) {
        rgsIsLoading = true

        let url = rgsServerUrl.trimmingCharacters(in: .whitespaces)

        do {
            // Save the configuration to settings first
            rgsConfigService.saveServerUrl(url)

            // Restart the Lightning node with the new RGS server
            let currentElectrumUrl = electrumConfigService.getCurrentServer().url
            try await lightningService.restart(electrumServerUrl: currentElectrumUrl, rgsServerUrl: url.isEmpty ? nil : url)

            rgsIsLoading = false

            Logger.info("Successfully connected to RGS server: \(url.isEmpty ? "disabled" : url)")

            return (success: true, url: url, errorMessage: nil)
        } catch {
            rgsIsLoading = false

            Logger.error(error, context: "Failed to connect to RGS server")

            return (success: false, url: url, errorMessage: error.localizedDescription)
        }
    }

    func onRgsScan(_ data: String) async -> (success: Bool, url: String, errorMessage: String?)? {
        // Validate scanned data
        guard isValidRgsUrl(data) else {
            return nil
        }

        rgsServerUrl = data

        // Try to connect
        return await connectToRgsServer()
    }
}
