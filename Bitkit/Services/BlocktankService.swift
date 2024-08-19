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
    
    func registerDevice(deviceToken: String) async throws {
        UserDefaults.standard.setValue(deviceToken, forKey: "deviceToken") //Token cached so we can retry registration if there are any issues
        
        guard let nodeId = LightningService.shared.nodeId else {
            throw AppError(serviceError: .nodeNotStarted)
        }
        
        Logger.debug("Registering device for notifications")
                
        let isoTimestamp = ISO8601DateFormatter().string(from: Date())
        let messageToSign = "bitkit-notifications\(deviceToken)\(isoTimestamp)"
        
        let signature = try await LightningService.shared.sign(message: messageToSign)
        
        let publicKey = "03864ef025fde8fb587d989186ce6a4a186895ee44a926bfc370e2c366597a3f8f"
        //TODO: use real public key like below to enable decryption of the push notification payload so we know which node event to wait for
        //https://github.com/SeverinAlexB/ln-verifymessagejs/blob/master/src/shared_secret.ts
        
        let params = [
            "deviceToken": deviceToken,
            "publicKey": publicKey,
            "features": [
                "blocktank.incomingHtlc"
            ],
            "nodeId": nodeId,
            "isoTimestamp": isoTimestamp,
            "signature": signature
        ] as [String : Any]
                
        let result = try await postRequest("notifications/api/device", params)
        Logger.info("Device registered: \(String(data: result, encoding: .utf8) ?? "")")
    }
    
    //TODO: token is cached above so occasionally check the status of the device with Blocktank. If not registered but we have a token then retry registration.
    
    func selfTest() async throws {
        guard let deviceToken = UserDefaults.standard.string(forKey: "deviceToken") else {
            throw BlocktankError.missingDeviceToken
        }
        
        Logger.debug("Sending test notification to self")
        
        let params = [
            "data": [
                "source": "blocktank",
                "type": "incomingHtlc",
                "payload": ["secretMessage": "hello"]
            ]
        ] as [String : Any]
                
        let result = try await postRequest("notifications/api/device/\(deviceToken)/test-notification", params)
        Logger.info("Notification sent to self: \(String(data: result, encoding: .utf8) ?? "")")
    }
}

extension BlocktankService {
    func postRequest(_ path: String, _ params: [String: Any] = [:]) async throws -> Data {
        return try await ServiceQueue.background(.blocktank) {
            let url = URL(string: "\(Env.blocktankUrl)/\(path)")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            
            request.httpBody = try JSONSerialization.data(withJSONObject: params, options: [])
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            
            Logger.debug("POST \(url.absoluteString)")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw BlocktankError.missingResponse
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                Logger.error("Invalid server response (\(httpResponse.statusCode)) from POST \(url.absoluteString)")
                
                if let responseBody = String(data: data, encoding: .utf8) {
                    Logger.error(responseBody)
                }
                
                throw BlocktankError.invalidResponse //TODO: add error status code
            }
            
            return data
        }
    }
    
    func getRequest(_ path: String, _ params: [String: String] = [:]) async throws -> Data {
        var urlComponents = URLComponents(string: "\(Env.blocktankUrl)/\(path)")!
        urlComponents.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        
        let url = urlComponents.url!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw BlocktankError.invalidResponse
        }
        
        return data
    }
}
