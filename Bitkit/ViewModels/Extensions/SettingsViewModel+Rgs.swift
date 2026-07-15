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

        // Re-validate the exact URL at connect time; the debounced rgsUrlIsValid can be stale
        // for ~300ms after the field changes, which would otherwise leave Connect enabled.
        let isValid = await Task.detached { [self] in isValidRgsUrl(url) }.value
        guard isValid else {
            rgsIsLoading = false
            return (success: false, url: url, errorMessage: nil)
        }

        // Verify the endpoint actually serves a snapshot before restarting the node; a
        // well-formed but wrong URL would otherwise report success. Empty URL disables RGS.
        if !url.isEmpty, await !isRgsEndpointReachable(url) {
            rgsIsLoading = false
            return (success: false, url: url, errorMessage: nil)
        }

        do {
            // Save the configuration to settings first
            rgsConfigService.saveServerUrl(url)

            // Restart the Lightning node with the new RGS server
            let currentElectrumUrl = electrumConfigService.getCurrentServer().fullUrl
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

    /// RGS servers serve snapshots at <url>/<lastSyncTimestamp>; timestamp 0 is the full snapshot
    /// and returns a 2xx for a valid endpoint, so a HEAD request confirms reachability without
    /// downloading the body. Mirrors the Android RGS connect check.
    nonisolated func isRgsEndpointReachable(_ url: String) async -> Bool {
        let base = url.hasSuffix("/") ? String(url.dropLast()) : url
        guard let testUrl = URL(string: "\(base)/0") else {
            return false
        }

        var request = URLRequest(url: testUrl)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return false
            }
            return (200 ... 299).contains(http.statusCode)
        } catch {
            Logger.warn("RGS endpoint unreachable at \(testUrl.absoluteString): \(error.localizedDescription)")
            return false
        }
    }

    func onRgsScan(_ data: String) async -> (success: Bool, url: String, errorMessage: String?)? {
        // Validate scanned data off the main thread (regex could block on pathological input)
        let isValid = await Task.detached { [self] in isValidRgsUrl(data) }.value
        guard isValid else {
            return nil
        }

        rgsServerUrl = data

        // Try to connect
        return await connectToRgsServer()
    }
}
