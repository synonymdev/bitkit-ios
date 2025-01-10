import Foundation

extension BlocktankService {
    /// Mines a number of blocks on the regtest network.
    /// - Parameter count: Number of blocks to mine. Default is 1.
    func regtestMine(count: Int = 1) async throws {
        let params = ["count": count] as [String: Any]
        _ = try await postRequest(Env.blocktankClientServer + "/regtest/chain/mine", params)
    }
    
    /// Deposits a number of satoshis to an address on the regtest network.
    /// - Parameters:
    ///   - address: Address to deposit to
    ///   - amountSat: Amount of satoshis to deposit. Default is 10_000_000
    /// - Returns: Onchain transaction id
    func regtestDeposit(address: String, amountSat: Int = 10_000_000) async throws -> String {
        let params = [
            "address": address,
            "amountSat": amountSat
        ] as [String: Any]
        
        let data = try await postRequest(Env.blocktankClientServer + "/regtest/chain/deposit", params)
        guard let txId = String(data: data, encoding: .utf8) else {
            throw BlocktankError_deprecated.invalidResponse
        }
        return txId
    }
    
    /// Pays an invoice on the regtest network
    /// - Parameters:
    ///   - invoice: Invoice to pay
    ///   - amountSat: Amount of satoshis to pay (only for 0 amt invoices)
    /// - Returns: Blocktank payment id
    func regtestPay(invoice: String, amountSat: Int? = nil) async throws -> String {
        var params: [String: Any] = ["invoice": invoice]
        if let amountSat = amountSat {
            params["amountSat"] = amountSat
        }
        
        let data = try await postRequest(Env.blocktankClientServer + "/regtest/channel/pay", params)
        guard let paymentId = String(data: data, encoding: .utf8) else {
            throw BlocktankError_deprecated.invalidResponse
        }
        return paymentId
    }
    
    /// Closes a channel on the regtest network
    /// - Parameters:
    ///   - fundingTxId: Funding transaction id
    ///   - vout: Funding transaction output index
    ///   - forceCloseAfterS: Time in seconds to force close the channel after. Default is 24hrs (86400). For force close set it to 0
    /// - Returns: Closing transaction id
    func regtestCloseChannel(fundingTxId: String, vout: Int, forceCloseAfterS: Int = 86400) async throws -> String {
        let params = [
            "fundingTxId": fundingTxId,
            "vout": vout,
            "forceCloseAfterS": forceCloseAfterS
        ] as [String: Any]
        
        let data = try await postRequest(Env.blocktankClientServer + "/regtest/channel/close", params)
        guard let closingTxId = String(data: data, encoding: .utf8) else {
            throw BlocktankError_deprecated.invalidResponse
        }
        return closingTxId
    }
}
