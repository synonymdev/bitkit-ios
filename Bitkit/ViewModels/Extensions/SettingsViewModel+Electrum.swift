import Foundation

// MARK: - Electrum Server Management

extension SettingsViewModel {
    func loadElectrumSettings() {
        // Check connection status first
        let isRunning = lightningService.status?.isRunning == true
        electrumIsConnected = isRunning

        // Update form with current server (stored or default)
        let currentServer = electrumConfigService.getCurrentServer()
        updateForm(with: currentServer)
    }

    func resetElectrumToDefault() async -> (success: Bool, host: String, port: String, errorMessage: String?) {
        let defaultServer = electrumConfigService.getDefaultServer()
        updateForm(with: defaultServer)

        return await connectToElectrumServer()
    }

    func connectToElectrumServer() async -> (success: Bool, host: String, port: String, errorMessage: String?) {
        electrumIsLoading = true

        let host = electrumHost.trimmingCharacters(in: .whitespaces)
        let port = electrumPort.trimmingCharacters(in: .whitespaces)

        // Validate input first
        if let validationError = validateElectrumInput(host: host, port: port) {
            electrumIsLoading = false
            return (success: false, host: host, port: port, errorMessage: validationError)
        }

        // Create server config (don't save yet - only save after successful connection)
        let serverConfig = ElectrumServer(
            host: host,
            portString: port,
            protocolType: electrumSelectedProtocol
        )

        do {
            // Restart the Lightning node with the new Electrum server
            let currentRgsUrl = rgsConfigService.getCurrentServerUrl()
            try await lightningService.restart(
                electrumServerUrl: serverConfig.fullUrl,
                rgsServerUrl: currentRgsUrl.isEmpty ? nil : currentRgsUrl
            )

            // Wait a bit for the connection to establish and verify it's actually working
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

            // Verify the node is actually running and connected
            guard let status = lightningService.status, status.isRunning else {
                electrumIsLoading = false
                Logger.error("Electrum connection failed: Node is not running after restart")

                // Reload form and connection status from actual current server (node may have fallen back to previous server)
                let actualServer = electrumConfigService.getCurrentServer()
                updateForm(with: actualServer)
                electrumCurrentServer = actualServer
                // Check if node is actually running with the previous server
                electrumIsConnected = lightningService.status?.isRunning == true

                return (success: false, host: host, port: port, errorMessage: t("settings__es__server_error_description"))
            }

            // Only save the configuration after successful connection validation
            electrumConfigService.saveServerConfig(serverConfig)
            electrumCurrentServer = serverConfig
            electrumIsConnected = true
            electrumIsLoading = false

            Logger.info("Successfully connected to Electrum server: \(serverConfig.fullUrl)")

            return (success: true, host: host, port: port, errorMessage: nil)
        } catch {
            electrumIsLoading = false

            Logger.error(error, context: "Failed to connect to Electrum server")

            // Reload form and connection status from actual current server (node may have fallen back to previous server)
            let actualServer = electrumConfigService.getCurrentServer()
            updateForm(with: actualServer)
            electrumCurrentServer = actualServer
            // Check if node is actually running with the previous server
            electrumIsConnected = lightningService.status?.isRunning == true

            return (success: false, host: host, port: port, errorMessage: nil)
        }
    }

    func onElectrumScan(_ data: String) async -> (success: Bool, host: String, port: String, errorMessage: String?)? {
        let parseResult = parseElectrumScanData(data)

        guard let serverPeer = parseResult else {
            // Return nil for invalid scan data
            return nil
        }

        updateForm(with: serverPeer)

        // Try to connect
        return await connectToElectrumServer()
    }

    private func updateForm(with server: ElectrumServer) {
        electrumHost = server.host
        electrumPort = server.portString
        electrumSelectedProtocol = server.protocolType
    }

    private func validateElectrumInput(host: String, port: String) -> String? {
        // Check if both host and port are empty
        if host.isEmpty && port.isEmpty {
            return t("settings__es__error_host_port")
        }

        // Check if host is empty
        if host.isEmpty {
            return t("settings__es__error_host")
        }

        // Check if port is empty
        if port.isEmpty {
            return t("settings__es__error_port")
        }

        // Check if port is a valid number
        guard let portInt = Int(port) else {
            return t("settings__es__error_port_invalid")
        }

        // Check port range
        guard portInt > 0 && portInt <= 65535 else {
            return t("settings__es__error_port_invalid")
        }

        // Check URL format
        let url = "\(host):\(port)"
        if !isValidElectrumURL(url) {
            return t("settings__es__error_invalid_http")
        }

        return nil // No validation errors
    }

    private func isValidElectrumURL(_ data: String) -> Bool {
        // Add 'http://' if the protocol is missing to enable URL parsing
        let normalizedData = data.hasPrefix("http://") || data.hasPrefix("https://") ? data : "http://\(data)"

        guard let url = URL(string: normalizedData) else {
            return false
        }

        let hostname = url.host ?? ""

        // Allow standard domains, custom TLDs like .local, and IPv4 addresses
        let isValidDomainOrIP =
            hostname.range(
                of: #"^([a-z\d]([a-z\d-]*[a-z\d])*\.)+[a-z\d-]+|(\d{1,3}\.){3}\d{1,3}$"#, options: .regularExpression, range: nil, locale: nil
            ) != nil

        // Always allow .local domains
        if hostname.hasSuffix(".local") {
            return true
        }

        // Allow localhost in development mode
        if Env.isDebug && data.contains("localhost") {
            return true
        }

        return isValidDomainOrIP
    }

    private func parseElectrumScanData(_ data: String) -> ElectrumServer? {
        // Handle URLs with tcp:// or ssl:// prefix
        if data.hasPrefix("tcp://") || data.hasPrefix("ssl://") {
            let protocolType: ElectrumProtocol = data.hasPrefix("ssl://") ? .ssl : .tcp
            let urlWithoutProtocol = String(data.dropFirst(6)) // Remove "ssl://" or "tcp://"
            let components = urlWithoutProtocol.split(separator: ":")

            guard components.count >= 2 else { return nil }

            let host = String(components[0])
            let port = String(components[1])

            return ElectrumServer(host: host, portString: port, protocolType: protocolType)
        }

        // Handle plain format: host:port or host:port:s (Umbrel format)
        if !data.hasPrefix("http://") && !data.hasPrefix("https://") {
            let parts = data.split(separator: ":")
            guard parts.count >= 2 else { return nil }

            let host = String(parts[0])
            let port = String(parts[1])
            let shortProtocol = parts.count > 2 ? String(parts[2]) : nil

            let protocolType: ElectrumProtocol = if let shortProtocol {
                // Support Umbrel connection URL format
                shortProtocol == "s" ? .ssl : .tcp
            } else {
                // Prefix protocol for common ports if missing
                electrumConfigService.getProtocolForPort(port)
            }

            return ElectrumServer(host: host, portString: port, protocolType: protocolType)
        }

        // Handle URLs with http:// or https:// prefix
        guard let url = URL(string: data) else { return nil }

        let host = url.host ?? ""
        let port = (url.port ?? 0) > 0 ? String(url.port ?? 0) : (url.scheme == "https" ? "443" : "80")
        let protocolType: ElectrumProtocol = url.scheme == "https" ? .ssl : .tcp

        return ElectrumServer(host: host, portString: port, protocolType: protocolType)
    }
}
