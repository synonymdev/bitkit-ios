//
//  PubkyRingSimulator.swift
//  BitkitTests
//
//  Simulates Pubky-ring responses for E2E and integration testing
//

import Foundation

/// Simulates Pubky-ring app responses for testing purposes
/// This allows E2E tests to run without requiring the actual Pubky-ring app
public class PubkyRingSimulator {
    
    public static let shared = PubkyRingSimulator()
    
    // Test data
    public static let testPubkey = "test123456789abcdefghijklmnopqrstuvwxyz"
    public static let testSessionSecret = "secret123456789abcdefghijklmnop"
    public static let testNoiseKey = "noise123456789abcdefghijklmnopqrst"
    
    private init() {}
    
    // MARK: - Session Simulation
    
    /// Inject a session callback as if Pubky-ring returned it
    /// - Parameters:
    ///   - pubkey: The pubkey to use (defaults to test pubkey)
    ///   - sessionSecret: The session secret to use (defaults to test secret)
    public func injectSessionCallback(
        pubkey: String = PubkyRingSimulator.testPubkey,
        sessionSecret: String = PubkyRingSimulator.testSessionSecret
    ) {
        let callbackUrl = URL(string: "bitkit://paykit-session?pubky=\(pubkey)&session_secret=\(sessionSecret)")!
        
        // Trigger the callback handler
        let handled = PubkyRingBridge.shared.handleCallback(url: callbackUrl)
        
        if !handled {
            print("PubkyRingSimulator: Failed to inject session callback")
        }
    }
    
    /// Inject a keypair callback
    /// - Parameters:
    ///   - pubkey: The public key
    ///   - privateKey: The private key (base64 encoded)
    public func injectKeypairCallback(
        pubkey: String = PubkyRingSimulator.testPubkey,
        privateKey: String = "privatekey123456789"
    ) {
        let callbackUrl = URL(string: "bitkit://paykit-keypair?pubkey=\(pubkey)&private_key=\(privateKey)")!
        
        let handled = PubkyRingBridge.shared.handleCallback(url: callbackUrl)
        
        if !handled {
            print("PubkyRingSimulator: Failed to inject keypair callback")
        }
    }
    
    /// Inject a profile callback
    /// - Parameters:
    ///   - name: Profile name
    ///   - bio: Profile bio
    ///   - pubkey: The pubkey
    public func injectProfileCallback(
        name: String = "Test User",
        bio: String = "Test bio",
        pubkey: String = PubkyRingSimulator.testPubkey
    ) {
        let profileJson = """
        {"name":"\(name)","bio":"\(bio)","pubkey":"\(pubkey)"}
        """
        let encoded = profileJson.data(using: .utf8)!.base64EncodedString()
        
        let callbackUrl = URL(string: "bitkit://paykit-profile?data=\(encoded)")!
        
        let handled = PubkyRingBridge.shared.handleCallback(url: callbackUrl)
        
        if !handled {
            print("PubkyRingSimulator: Failed to inject profile callback")
        }
    }
    
    /// Inject a follows list callback
    /// - Parameter follows: List of pubkeys being followed
    public func injectFollowsCallback(follows: [String] = []) {
        let followsJson = try? JSONSerialization.data(withJSONObject: follows)
        let encoded = followsJson?.base64EncodedString() ?? ""
        
        let callbackUrl = URL(string: "bitkit://paykit-follows?data=\(encoded)")!
        
        let handled = PubkyRingBridge.shared.handleCallback(url: callbackUrl)
        
        if !handled {
            print("PubkyRingSimulator: Failed to inject follows callback")
        }
    }
    
    // MARK: - Test Session Helpers
    
    /// Create a test PubkySession
    public func createTestSession(
        pubkey: String = PubkyRingSimulator.testPubkey,
        sessionSecret: String = PubkyRingSimulator.testSessionSecret
    ) -> PubkySession {
        return PubkySession(
            pubkey: pubkey,
            sessionSecret: sessionSecret
        )
    }
    
    /// Directly cache a test session in PubkyRingBridge
    public func cacheTestSession(
        pubkey: String = PubkyRingSimulator.testPubkey,
        sessionSecret: String = PubkyRingSimulator.testSessionSecret
    ) {
        let session = createTestSession(pubkey: pubkey, sessionSecret: sessionSecret)
        PubkyRingBridge.shared.cacheSession(session)
    }
    
    // MARK: - Cleanup
    
    /// Clear all cached sessions and state
    public func reset() {
        PubkyRingBridge.shared.clearCache()
    }
}

// MARK: - Test Assertion Helpers

extension PubkyRingSimulator {
    
    /// Verify that a session was successfully cached
    public func assertSessionCached(for pubkey: String = PubkyRingSimulator.testPubkey) -> Bool {
        return PubkyRingBridge.shared.getCachedSession(for: pubkey) != nil
    }
    
    /// Get the cached session for verification
    public func getCachedSession(for pubkey: String = PubkyRingSimulator.testPubkey) -> PubkySession? {
        return PubkyRingBridge.shared.getCachedSession(for: pubkey)
    }
}

