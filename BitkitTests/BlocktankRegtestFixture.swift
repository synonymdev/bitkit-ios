import Foundation

enum BlocktankRegtestFixture {
    enum FixtureError: LocalizedError {
        case missingAuth
        case invalidResponse
        case httpFailure(route: String, status: Int)

        var errorDescription: String? {
            switch self {
            case .missingAuth: "Set TEST_RUNNER_BLOCKTANK_REGTEST_AUTH to the staging Blocktank credential."
            case .invalidResponse: "Blocktank returned an invalid regtest fixture response."
            case let .httpFailure(route, status): "Blocktank regtest \(route) returned HTTP \(status)."
            }
        }
    }

    static func depositFunds(address: String, amountSat: UInt64) async throws -> String {
        let data = try await post("deposit", body: ["address": address, "amountSat": amountSat])
        guard let txid = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !txid.isEmpty
        else {
            throw FixtureError.invalidResponse
        }
        return txid
    }

    static func mineBlocks(_ count: UInt32) async throws {
        _ = try await post("mine", body: ["count": count])
    }

    private static func post(_ route: String, body: [String: Any]) async throws -> Data {
        // This credential is only for the staging fixture API. Wallet behavior uses the app's normal services.
        let url = URL(string: "https://api.stag0.blocktank.to/blocktank/api/v2/regtest/chain")!
        guard let auth = ProcessInfo.processInfo.environment["BLOCKTANK_REGTEST_AUTH"], !auth.isEmpty else {
            throw FixtureError.missingAuth
        }

        var request = URLRequest(url: url.appendingPathComponent(route), timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic \(Data(auth.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw FixtureError.invalidResponse }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw FixtureError.httpFailure(route: route, status: response.statusCode)
        }
        return data
    }
}
