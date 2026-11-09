import Foundation

/// Funds and mines on the local regtest bitcoind from bitkit-docker. The wallet under test reaches
/// that chain through the stack's electrs when the test runs with `E2E=true` (see `Env.electrumServerUrl`).
enum LocalRegtest {
    private static let rpcUrl = URL(string: ProcessInfo.processInfo.environment["BITCOIN_RPC_URL"] ?? "http://127.0.0.1:43782")!
    private static let rpcAuth = Data("polaruser:polarpass".utf8).base64EncodedString()

    private struct RpcResponse<T: Decodable>: Decodable {
        let result: T?
        let error: RpcErrorBody?
    }

    private struct RpcErrorBody: Decodable {
        let message: String
    }

    private struct RpcError: Error, CustomStringConvertible {
        let description: String
    }

    private static func call<T: Decodable>(_ method: String, _ params: [Any] = []) async throws -> T {
        var request = URLRequest(url: rpcUrl, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Basic \(rpcAuth)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "1.0", "id": method, "method": method, "params": params])

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(RpcResponse<T>.self, from: data)
        if let error = response.error {
            throw RpcError(description: "bitcoind \(method) failed: \(error.message)")
        }
        guard let result = response.result else {
            throw RpcError(description: "bitcoind \(method) returned no result")
        }
        return result
    }

    /// Sends `amountSat` to `address` from the bitcoind wallet and returns the txid.
    static func deposit(address: String, amountSat: UInt64) async throws -> String {
        let btc = String(format: "%llu.%08llu", amountSat / 100_000_000, amountSat % 100_000_000)
        return try await call("sendtoaddress", [address, btc])
    }

    static func mineBlocks(_ count: Int = 1) async throws {
        let address: String = try await call("getnewaddress")
        let _: [String] = try await call("generatetoaddress", [count, address])
    }
}
