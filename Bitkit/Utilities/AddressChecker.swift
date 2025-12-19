import Foundation

struct AddressStats: Codable {
    let funded_txo_count: Int
    let funded_txo_sum: Int
    let spent_txo_count: Int
    let spent_txo_sum: Int
    let tx_count: Int
}

struct EsploraAddressInfo: Codable {
    let address: String
    let chain_stats: AddressStats
    let mempool_stats: AddressStats
}

struct EsploraTxInput: Codable {
    let txid: String?
    let vout: Int?
    let prevout: EsploraTxOutput?
    let scriptsig: String?
    let scriptsig_asm: String?
    let witness: [String]?
    let is_coinbase: Bool?
    let sequence: Int64?
}

struct EsploraTxOutput: Codable {
    let scriptpubkey: String
    let scriptpubkey_asm: String?
    let scriptpubkey_type: String?
    let scriptpubkey_address: String?
    let value: Int64
    let n: Int?
}

struct EsploraTxStatus: Codable {
    let confirmed: Bool
    let block_height: Int?
    let block_hash: String?
    let block_time: Int64?
}

struct EsploraTxDetails: Codable {
    let txid: String
    let vin: [EsploraTxInput]
    let vout: [EsploraTxOutput]
    let status: EsploraTxStatus
}

enum AddressCheckerError: Error {
    case invalidUrl
    case networkError(Error)
    case invalidResponse
}

/// TEMPORARY IMPLEMENTATION
/// This is a short-term solution for getting address information using electrs.
/// Eventually, this will be replaced by similar features in bitkit-core or ldk-node
/// when they support native address lookup.
class AddressChecker {
    static func getAddressInfo(address: String) async throws -> EsploraAddressInfo {
        guard let url = URL(string: "\(Env.esploraServerUrl)/address/\(address)") else {
            throw AddressCheckerError.invalidUrl
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200
            else {
                throw AddressCheckerError.invalidResponse
            }

            let decoder = JSONDecoder()
            return try decoder.decode(EsploraAddressInfo.self, from: data)
        } catch let error as DecodingError {
            throw AddressCheckerError.invalidResponse
        } catch {
            throw AddressCheckerError.networkError(error)
        }
    }

    /// Fetches full transaction details from the Esplora endpoint for the given txid.
    /// - Parameter txid: Hex transaction identifier.
    static func getTransaction(txid: String) async throws -> EsploraTxDetails {
        guard let url = URL(string: "\(Env.esploraServerUrl)/tx/\(txid)") else {
            throw AddressCheckerError.invalidUrl
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200
            else {
                throw AddressCheckerError.invalidResponse
            }

            let decoder = JSONDecoder()
            return try decoder.decode(EsploraTxDetails.self, from: data)
        } catch let error as DecodingError {
            Logger.error("decoding error \(error)")
            throw AddressCheckerError.invalidResponse
        } catch {
            throw AddressCheckerError.networkError(error)
        }
    }
}
