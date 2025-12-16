//
//  PubkyStorageAdapter.swift
//  Bitkit
//
//  Adapter for Pubky SDK storage operations
//  Uses URLSession for HTTP requests to Pubky homeservers
//

import Foundation
// PaykitMobile types are available from FFI/PaykitMobile.swift

/// Adapter for Pubky SDK storage operations
/// This provides a simplified interface to Pubky storage
public final class PubkyStorageAdapter {
    
    public static let shared = PubkyStorageAdapter()
    
    private let session: URLSession
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }
    
    /// Store data in Pubky storage (requires authenticated adapter)
    public func store(path: String, data: Data, adapter: PubkyAuthenticatedStorageAdapter) async throws {
        let content = String(data: data, encoding: .utf8) ?? ""
        let result = adapter.put(path: path, content: content)
        if !result.success {
            throw PubkyStorageError.saveFailed(result.error ?? "Unknown error")
        }
        Logger.debug("Stored data to Pubky: \(path)", context: "PubkyStorageAdapter")
    }
    
    /// Retrieve data from Pubky storage
    public func retrieve(path: String, adapter: PubkyUnauthenticatedStorageAdapter, ownerPubkey: String) async throws -> Data? {
        let result = adapter.get(ownerPubkey: ownerPubkey, path: path)
        if !result.success {
            throw PubkyStorageError.retrieveFailed(result.error ?? "Unknown error")
        }
        return result.content?.data(using: .utf8)
    }
    
    /// List items in a directory
    public func listDirectory(path: String, adapter: PubkyUnauthenticatedStorageAdapter, ownerPubkey: String) async throws -> [String] {
        let result = adapter.list(ownerPubkey: ownerPubkey, prefix: path)
        if !result.success {
            throw PubkyStorageError.listFailed(result.error ?? "Unknown error")
        }
        return result.entries
    }
    
    /// Read a file from Pubky storage (unauthenticated)
    public func readFile(path: String, adapter: Any, ownerPubkey: String) async throws -> Data? {
        if let unauthAdapter = adapter as? PubkyUnauthenticatedStorageAdapter {
            let result = unauthAdapter.get(ownerPubkey: ownerPubkey, path: path)
            if !result.success {
                if result.error?.contains("404") == true {
                    return nil
                }
                throw PubkyStorageError.retrieveFailed(result.error ?? "Unknown error")
            }
            return result.content?.data(using: .utf8)
        } else if let _ = adapter as? UnauthenticatedTransportFfi {
            // For FFI transport, use URLSession directly
            let urlString = "https://homeserver.pubky.app/\(ownerPubkey)\(path)"
            guard let url = URL(string: urlString) else { return nil }
            
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            
            if httpResponse.statusCode == 404 {
                return nil
            }
            if httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 {
                return data
            }
            throw PubkyStorageError.retrieveFailed("HTTP \(httpResponse.statusCode)")
        }
        return nil
    }
    
    /// Write a file to Pubky storage (requires authentication)
    public func writeFile(path: String, data: Data, transport: AuthenticatedTransportFfi) async throws {
        let content = String(data: data, encoding: .utf8) ?? ""
        let urlString = "https://homeserver.pubky.app\(path)"
        guard let url = URL(string: urlString) else {
            throw PubkyStorageError.saveFailed("Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = content.data(using: .utf8)
        
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PubkyStorageError.saveFailed("Invalid HTTP response")
        }
        
        if httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 {
            throw PubkyStorageError.saveFailed("HTTP \(httpResponse.statusCode)")
        }
    }
    
    /// Delete a file from Pubky storage (requires authentication)
    public func deleteFile(path: String, transport: AuthenticatedTransportFfi) async throws {
        let urlString = "https://homeserver.pubky.app\(path)"
        guard let url = URL(string: urlString) else {
            throw PubkyStorageError.deleteFailed("Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PubkyStorageError.deleteFailed("Invalid HTTP response")
        }
        
        // 204 No Content, 200 OK, or 404 Not Found are all valid
        if httpResponse.statusCode < 200 || (httpResponse.statusCode >= 300 && httpResponse.statusCode != 404) {
            throw PubkyStorageError.deleteFailed("HTTP \(httpResponse.statusCode)")
        }
    }
}

enum PubkyStorageError: LocalizedError {
    case saveFailed(String)
    case retrieveFailed(String)
    case listFailed(String)
    case deleteFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .saveFailed(let msg):
            return "Failed to save to Pubky storage: \(msg)"
        case .retrieveFailed(let msg):
            return "Failed to retrieve from Pubky storage: \(msg)"
        case .listFailed(let msg):
            return "Failed to list Pubky directory: \(msg)"
        case .deleteFailed(let msg):
            return "Failed to delete from Pubky storage: \(msg)"
        }
    }
}

/// Adapter for unauthenticated (read-only) Pubky storage operations
/// Makes HTTP requests to Pubky homeservers to read public data
public class PubkyUnauthenticatedStorageAdapter: PubkyUnauthenticatedStorageCallback {
    
    private let homeserverBaseURL: String?
    private let session: URLSession
    
    public init(homeserverBaseURL: String? = nil) {
        self.homeserverBaseURL = homeserverBaseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }
    
    public func get(ownerPubkey: String, path: String) -> StorageGetResult {
        let urlString = if let baseURL = homeserverBaseURL {
            "\(baseURL)/pubky\(ownerPubkey)\(path)"
        } else {
            "https://_pubky.\(ownerPubkey)\(path)"
        }
        
        guard let url = URL(string: urlString) else {
            return StorageGetResult(success: false, content: nil, error: "Invalid URL")
        }
        
        var result: StorageGetResult?
        let semaphore = DispatchSemaphore(value: 0)
        
        let task = session.dataTask(with: url) { data, response, error in
            defer { semaphore.signal() }
            
            if let error = error {
                result = StorageGetResult(success: false, content: nil, error: "Network error: \(error.localizedDescription)")
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                result = StorageGetResult(success: false, content: nil, error: "Invalid HTTP response")
                return
            }
            
            switch httpResponse.statusCode {
            case 404:
                result = StorageGetResult(success: true, content: nil, error: nil)
            case 200...299:
                let content = data.flatMap { String(data: $0, encoding: .utf8) }
                result = StorageGetResult(success: true, content: content, error: nil)
            default:
                result = StorageGetResult(success: false, content: nil, error: "HTTP \(httpResponse.statusCode)")
            }
        }
        
        task.resume()
        semaphore.wait()
        
        return result ?? StorageGetResult(success: false, content: nil, error: "Unknown error")
    }
    
    public func list(ownerPubkey: String, prefix: String) -> StorageListResult {
        let urlString = if let baseURL = homeserverBaseURL {
            "\(baseURL)/pubky\(ownerPubkey)\(prefix)?shallow=true"
        } else {
            "https://_pubky.\(ownerPubkey)\(prefix)?shallow=true"
        }
        
        guard let url = URL(string: urlString) else {
            return StorageListResult(success: false, entries: [], error: "Invalid URL")
        }
        
        var result: StorageListResult?
        let semaphore = DispatchSemaphore(value: 0)
        
        let task = session.dataTask(with: url) { data, response, error in
            defer { semaphore.signal() }
            
            if let error = error {
                result = StorageListResult(success: false, entries: [], error: "Network error: \(error.localizedDescription)")
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                result = StorageListResult(success: false, entries: [], error: "Invalid HTTP response")
                return
            }
            
            switch httpResponse.statusCode {
            case 404:
                result = StorageListResult(success: true, entries: [], error: nil)
            case 200...299:
                guard let data = data, let jsonString = String(data: data, encoding: .utf8) else {
                    result = StorageListResult(success: true, entries: [], error: nil)
                    return
                }
                
                // Parse JSON array
                if let jsonData = jsonString.data(using: .utf8),
                   let jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
                    let entries = jsonArray.compactMap { $0["path"] as? String }
                    result = StorageListResult(success: true, entries: entries, error: nil)
                } else if let jsonData = jsonString.data(using: .utf8),
                          let jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [String] {
                    result = StorageListResult(success: true, entries: jsonArray, error: nil)
                } else {
                    result = StorageListResult(success: false, entries: [], error: "Failed to parse response")
                }
            default:
                result = StorageListResult(success: false, entries: [], error: "HTTP \(httpResponse.statusCode)")
            }
        }
        
        task.resume()
        semaphore.wait()
        
        return result ?? StorageListResult(success: false, entries: [], error: "Unknown error")
    }
}

/// Adapter for authenticated Pubky storage operations
/// Makes HTTP requests to Pubky homeservers with session authentication
public class PubkyAuthenticatedStorageAdapter: PubkyAuthenticatedStorageCallback {
    
    private let sessionId: String
    private let homeserverBaseURL: String?
    private let session: URLSession
    
    public init(sessionId: String, homeserverBaseURL: String? = nil) {
        self.sessionId = sessionId
        self.homeserverBaseURL = homeserverBaseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpCookieStorage = HTTPCookieStorage.shared
        self.session = URLSession(configuration: config)
    }
    
    public func put(path: String, content: String) -> StorageOperationResult {
        let urlString = if let baseURL = homeserverBaseURL {
            "\(baseURL)\(path)"
        } else {
            "https://homeserver.pubky.app\(path)"
        }
        
        guard let url = URL(string: urlString) else {
            return StorageOperationResult(success: false, error: "Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("session=\(sessionId)", forHTTPHeaderField: "Cookie")
        request.httpBody = content.data(using: .utf8)
        
        var result: StorageOperationResult?
        let semaphore = DispatchSemaphore(value: 0)
        
        let task = session.dataTask(with: request) { _, response, error in
            defer { semaphore.signal() }
            
            if let error = error {
                result = StorageOperationResult(success: false, error: "Network error: \(error.localizedDescription)")
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                result = StorageOperationResult(success: false, error: "Invalid HTTP response")
                return
            }
            
            if (200...299).contains(httpResponse.statusCode) {
                result = StorageOperationResult(success: true, error: nil)
            } else {
                result = StorageOperationResult(success: false, error: "HTTP \(httpResponse.statusCode)")
            }
        }
        
        task.resume()
        semaphore.wait()
        
        return result ?? StorageOperationResult(success: false, error: "Unknown error")
    }
    
    public func get(path: String) -> StorageGetResult {
        let urlString = if let baseURL = homeserverBaseURL {
            "\(baseURL)\(path)"
        } else {
            "https://homeserver.pubky.app\(path)"
        }
        
        guard let url = URL(string: urlString) else {
            return StorageGetResult(success: false, content: nil, error: "Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("session=\(sessionId)", forHTTPHeaderField: "Cookie")
        
        var result: StorageGetResult?
        let semaphore = DispatchSemaphore(value: 0)
        
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            
            if let error = error {
                result = StorageGetResult(success: false, content: nil, error: "Network error: \(error.localizedDescription)")
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                result = StorageGetResult(success: false, content: nil, error: "Invalid HTTP response")
                return
            }
            
            switch httpResponse.statusCode {
            case 404:
                result = StorageGetResult(success: true, content: nil, error: nil)
            case 200...299:
                let content = data.flatMap { String(data: $0, encoding: .utf8) }
                result = StorageGetResult(success: true, content: content, error: nil)
            default:
                result = StorageGetResult(success: false, content: nil, error: "HTTP \(httpResponse.statusCode)")
            }
        }
        
        task.resume()
        semaphore.wait()
        
        return result ?? StorageGetResult(success: false, content: nil, error: "Unknown error")
    }
    
    public func delete(path: String) -> StorageOperationResult {
        let urlString = if let baseURL = homeserverBaseURL {
            "\(baseURL)\(path)"
        } else {
            "https://homeserver.pubky.app\(path)"
        }
        
        guard let url = URL(string: urlString) else {
            return StorageOperationResult(success: false, error: "Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("session=\(sessionId)", forHTTPHeaderField: "Cookie")
        
        var result: StorageOperationResult?
        let semaphore = DispatchSemaphore(value: 0)
        
        let task = session.dataTask(with: request) { _, response, error in
            defer { semaphore.signal() }
            
            if let error = error {
                result = StorageOperationResult(success: false, error: "Network error: \(error.localizedDescription)")
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                result = StorageOperationResult(success: false, error: "Invalid HTTP response")
                return
            }
            
            // 204 No Content or 200 OK are both valid for DELETE
            if (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 404 {
                result = StorageOperationResult(success: true, error: nil)
            } else {
                result = StorageOperationResult(success: false, error: "HTTP \(httpResponse.statusCode)")
            }
        }
        
        task.resume()
        semaphore.wait()
        
        return result ?? StorageOperationResult(success: false, error: "Unknown error")
    }
    
    public func list(prefix: String) -> StorageListResult {
        let urlString = if let baseURL = homeserverBaseURL {
            "\(baseURL)\(prefix)?shallow=true"
        } else {
            "https://homeserver.pubky.app\(prefix)?shallow=true"
        }
        
        guard let url = URL(string: urlString) else {
            return StorageListResult(success: false, entries: [], error: "Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("session=\(sessionId)", forHTTPHeaderField: "Cookie")
        
        var result: StorageListResult?
        let semaphore = DispatchSemaphore(value: 0)
        
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            
            if let error = error {
                result = StorageListResult(success: false, entries: [], error: "Network error: \(error.localizedDescription)")
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                result = StorageListResult(success: false, entries: [], error: "Invalid HTTP response")
                return
            }
            
            switch httpResponse.statusCode {
            case 404:
                result = StorageListResult(success: true, entries: [], error: nil)
            case 200...299:
                guard let data = data, let jsonString = String(data: data, encoding: .utf8) else {
                    result = StorageListResult(success: true, entries: [], error: nil)
                    return
                }
                
                // Parse JSON array
                if let jsonData = jsonString.data(using: .utf8),
                   let jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
                    let entries = jsonArray.compactMap { $0["path"] as? String }
                    result = StorageListResult(success: true, entries: entries, error: nil)
                } else if let jsonData = jsonString.data(using: .utf8),
                          let jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [String] {
                    result = StorageListResult(success: true, entries: jsonArray, error: nil)
                } else {
                    result = StorageListResult(success: false, entries: [], error: "Failed to parse response")
                }
            default:
                result = StorageListResult(success: false, entries: [], error: "HTTP \(httpResponse.statusCode)")
            }
        }
        
        task.resume()
        semaphore.wait()
        
        return result ?? StorageListResult(success: false, entries: [], error: "Unknown error")
    }
}

