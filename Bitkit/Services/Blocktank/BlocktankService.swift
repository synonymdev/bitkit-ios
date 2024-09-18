//
//  BlocktankService.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/14.
//

import Foundation

class BlocktankService {
    static var shared = BlocktankService()
    private init() {}
        
    func getInfo() async throws -> BtInfo {
        let data = try await getRequest(Env.blocktankClientServer + "/info")
        return try JSONDecoder().decode(BtInfo.self, from: data)
    }
    
    func postRequest(_ urlStr: String, _ params: [String: Any] = [:]) async throws -> Data {
        return try await ServiceQueue.background(.blocktank) {
            let url = URL(string: urlStr)!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            
            request.httpBody = try JSONSerialization.data(withJSONObject: params, options: [])
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            
            Logger.debug("POST \(url.absoluteString)")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw BlocktankError.missingResponse
            }
            
            if Env.isDebug {
                // Don't want to include possibly sensitive data in production logs
                if let json = try? JSONSerialization.jsonObject(with: data, options: []) {
                    Logger.debug(json)
                }
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                Logger.error("Invalid server response (\(httpResponse.statusCode)) from POST \(url.absoluteString)")
                
                if let responseBody = String(data: data, encoding: .utf8) {
                    Logger.error(responseBody)
                }
                
                throw BlocktankError.invalidResponse // TODO: add error status code
            }
            
            return data
        }
        
        // bitkitLog
    }
    
    func getRequest(_ url: String, _ params: [String: Any] = [:]) async throws -> Data {
        var urlComponents = URLComponents(string: url)!
//        urlComponents.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        
        urlComponents.queryItems = params.flatMap { key, value -> [URLQueryItem] in
            if let array = value as? [Any] {
                // If the value is an array, create a query item for each element
                return array.map { URLQueryItem(name: "\(key)[]", value: "\($0)") }
            } else {
                // Otherwise, create a single query item
                return [URLQueryItem(name: key, value: "\(value)")]
            }
        }
        
        let url = urlComponents.url!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BlocktankError.missingResponse
        }
        
        if Env.isDebug {
            // Don't want to include possibly sensitive data in production logs
            if let json = try? JSONSerialization.jsonObject(with: data, options: []) {
                Logger.debug(json)
            }
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            Logger.error("Invalid BT server response (\(httpResponse.statusCode)) from GET \(url.absoluteString)")
            throw BlocktankError.invalidResponse
        }
        
        return data
    }
}
