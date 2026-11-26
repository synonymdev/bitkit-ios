import Network
import XCTest

extension XCUIApplication {
    /// UI test builds run on regtest against staging Electrum. When `element` never appears and
    /// staging Electrum doesn't answer, skip instead of failing, so a staging outage doesn't block
    /// every PR. With Electrum answering, the caller's assertion fails as before.
    func skipIfBitcoinNodeUnavailable(waitingFor element: XCUIElement, timeout: TimeInterval) throws {
        guard !element.waitForExistence(timeout: timeout), !StagingElectrum.answers() else { return }
        throw XCTSkip("Requires staging regtest Electrum (\(StagingElectrum.host):\(StagingElectrum.port)), which isn't answering")
    }
}

/// The regtest server from `Env.electrumServerUrl(for: .regtest)`.
enum StagingElectrum {
    static let host = "electrs.bitkit.stag0.blocktank.to"
    static let port: UInt16 = 9999

    /// Whether the server answers a JSON-RPC request over TLS within `timeout`.
    static func answers(timeout: TimeInterval = 10) -> Bool {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tls)
        let answered = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            let request = Data("{\"id\":1,\"method\":\"server.version\",\"params\":[\"bitkit-uitests\",\"1.4\"]}\n".utf8)
            connection.send(content: request, completion: .contentProcessed { _ in })
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                if let data, !data.isEmpty {
                    answered.signal()
                }
            }
        }
        connection.start(queue: .global())
        defer { connection.cancel() }
        return answered.wait(timeout: .now() + timeout) == .success
    }
}
