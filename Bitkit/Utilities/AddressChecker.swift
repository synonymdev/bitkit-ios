//
//  AddressChecker.swift
//  Bitkit
//

import Foundation

struct AddressStats: Codable {
    let funded_txo_count: Int
    let funded_txo_sum: Int
    let spent_txo_count: Int
    let spent_txo_sum: Int
    let tx_count: Int
}

struct AddressInfo: Codable {
    let address: String
    let chain_stats: AddressStats
    let mempool_stats: AddressStats
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
    static func getAddressInfo(address: String) async throws -> AddressInfo {
        guard let url = URL(string: "\(Env.esploraServerUrl)/address/\(address)") else {
            throw AddressCheckerError.invalidUrl
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw AddressCheckerError.invalidResponse
            }
            
            let decoder = JSONDecoder()
            return try decoder.decode(AddressInfo.self, from: data)
        } catch let error as DecodingError {
            throw AddressCheckerError.invalidResponse
        } catch {
            throw AddressCheckerError.networkError(error)
        }
    }
}
