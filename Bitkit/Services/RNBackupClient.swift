import CommonCrypto
import CryptoKit
import Foundation
import LightningDevKit

enum RNBackupError: Error, LocalizedError {
    case notSetup
    case missingResponse
    case invalidServerResponse(String)
    case decryptFailed(String)
    case authFailed
    case noBackupFound

    var errorDescription: String? {
        switch self {
        case .notSetup:
            return "RN Backup client requires setup"
        case .missingResponse:
            return "Missing response from backup server"
        case let .invalidServerResponse(msg):
            return "Invalid backup server response: \(msg)"
        case let .decryptFailed(msg):
            return "Failed to decrypt backup: \(msg)"
        case .authFailed:
            return "Authentication with backup server failed"
        case .noBackupFound:
            return "No backup found on server"
        }
    }
}

struct RNBackupListResponse: Codable {
    let list: [String]
    let channel_monitors: [String]
}

private struct AuthChallengeResponse: Codable {
    let challenge: String
}

private struct AuthBearerResponse: Codable {
    let bearer: String
    let expires: Int
}

class RNBackupClient {
    static let shared = RNBackupClient()

    private static let version = "v1"
    private static let signedMessagePrefix = "react-native-ldk backup server auth:"

    private var secretKey: Data?
    private var publicKey: Data?
    private var network: String?
    private var serverHost: String?
    private var cachedBearer: AuthBearerResponse?

    private var encryptionKey: SymmetricKey? {
        guard let secretKey else { return nil }
        return SymmetricKey(data: secretKey)
    }

    private init() {}

    func setup(mnemonic: String, passphrase: String?) async throws {
        let seed = try deriveSeed(mnemonic: mnemonic, passphrase: passphrase)
        secretKey = seed
        publicKey = try Crypto.getPublicKey(privateKey: seed)
        serverHost = Env.rnBackupServerHost
        network = networkString()
        cachedBearer = nil
    }

    func reset() {
        secretKey = nil
        publicKey = nil
        network = nil
        cachedBearer = nil
    }

    private func networkString() -> String {
        switch Env.network {
        case .bitcoin: "bitcoin"
        case .testnet: "testnet"
        case .regtest: "regtest"
        case .signet: "signet"
        }
    }

    private func deriveSeed(mnemonic: String, passphrase: String?) throws -> Data {
        let mnemonicData = Data(mnemonic.utf8)
        let salt = "mnemonic" + (passphrase ?? "")
        let saltData = Data(salt.utf8)

        var bip39Seed = [UInt8](repeating: 0, count: 64)
        let pbkdfResult = bip39Seed.withUnsafeMutableBytes { seedPtr in
            mnemonicData.withUnsafeBytes { mnemonicPtr in
                saltData.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        mnemonicPtr.bindMemory(to: Int8.self).baseAddress!,
                        mnemonicData.count,
                        saltPtr.bindMemory(to: UInt8.self).baseAddress!,
                        saltData.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        2048,
                        seedPtr.bindMemory(to: UInt8.self).baseAddress!,
                        64
                    )
                }
            }
        }

        guard pbkdfResult == kCCSuccess else {
            throw RNBackupError.authFailed
        }

        let hmacKey = Data("Bitcoin seed".utf8)
        let seedData = Data(bip39Seed)

        var hmacOutput = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        hmacKey.withUnsafeBytes { keyPtr in
            seedData.withUnsafeBytes { seedPtr in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA512),
                    keyPtr.baseAddress!,
                    hmacKey.count,
                    seedPtr.baseAddress!,
                    seedData.count,
                    &hmacOutput
                )
            }
        }

        let bip32Seed = [UInt8](hmacOutput.prefix(32))

        let currentTime = Date()
        let seconds = UInt64(currentTime.timeIntervalSince1970)
        let nanoSeconds = UInt32((currentTime.timeIntervalSince1970.truncatingRemainder(dividingBy: 1)) * 1_000_000_000)

        let keysManager = KeysManager(
            seed: bip32Seed,
            startingTimeSecs: seconds,
            startingTimeNanos: nanoSeconds
        )

        return Data(keysManager.getNodeSecretKey())
    }

    // MARK: - Public API

    func listFiles(fileGroup: String? = "ldk") async throws -> RNBackupListResponse {
        let bearer = try await getAuthToken()
        let url = try buildUrl(method: "list", fileGroup: fileGroup)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(bearer, forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            Logger.error("RN Backup listFiles failed: status=\(statusCode) body=\(body)", context: "RNBackup")
            throw RNBackupError.invalidServerResponse("List files failed")
        }

        return try JSONDecoder().decode(RNBackupListResponse.self, from: data)
    }

    func retrieve(label: String, fileGroup: String? = nil) async throws -> Data {
        let bearer = try await getAuthToken()
        let url = try buildUrl(method: "retrieve", label: label, fileGroup: fileGroup)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(bearer, forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw RNBackupError.invalidServerResponse("Retrieve \(label) failed")
        }

        return try decrypt(data)
    }

    func hasBackup() async throws -> Bool {
        let ldkFiles = try await listFiles(fileGroup: "ldk")
        let bitkitFiles = try await listFiles(fileGroup: "bitkit")
        return !ldkFiles.list.isEmpty || !ldkFiles.channel_monitors.isEmpty || !bitkitFiles.list.isEmpty
    }

    func getLatestBackupTimestamp() async throws -> UInt64? {
        struct BackupWithMetadata: Codable {
            struct Metadata: Codable {
                let timestamp: Int64?
            }

            let metadata: Metadata?
        }

        let labels = [
            "bitkit_settings",
            "bitkit_metadata",
            "bitkit_widgets",
            "bitkit_lightning_activity",
            "bitkit_wallet",
            "bitkit_blocktank_orders",
        ]
        var latestTimestamp: UInt64?

        for label in labels {
            guard let data = try? await retrieve(label: label, fileGroup: "bitkit") else { continue }
            guard let backup = try? JSONDecoder().decode(BackupWithMetadata.self, from: data),
                  let timestamp = backup.metadata?.timestamp
            else { continue }

            let ts = UInt64(timestamp / 1000) // Convert ms to seconds
            if latestTimestamp == nil || ts > latestTimestamp! {
                latestTimestamp = ts
            }
        }

        return latestTimestamp
    }

    func retrieveChannelMonitor(channelId: String) async throws -> Data {
        let bearer = try await getAuthToken()
        let url = try buildUrl(method: "retrieve", label: "channel_monitor", fileGroup: "ldk", channelId: channelId)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(bearer, forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw RNBackupError.invalidServerResponse("Retrieve channel_monitor \(channelId) failed")
        }

        return try decrypt(data)
    }

    // MARK: - Private Helpers

    private func buildUrl(method: String, label: String? = nil, fileGroup: String? = nil, channelId: String? = nil) throws -> URL {
        guard let serverHost, let network else {
            throw RNBackupError.notSetup
        }

        var urlString = "\(serverHost)/\(Self.version)/\(method)?network=\(network)"

        if let label {
            urlString += "&label=\(label)"
        }
        if let fileGroup {
            urlString += "&fileGroup=\(fileGroup)"
        }
        if let channelId {
            urlString += "&channelId=\(channelId)"
        }

        guard let url = URL(string: urlString) else {
            throw RNBackupError.invalidServerResponse("Invalid URL")
        }

        return url
    }

    private func getAuthToken() async throws -> String {
        // Return cached token if still valid
        if let cached = cachedBearer {
            let expiresAt = Double(cached.expires) / 1000.0
            if expiresAt > Date().timeIntervalSince1970 {
                return cached.bearer
            }
        }

        guard let publicKey, secretKey != nil else {
            throw RNBackupError.notSetup
        }

        let pubKeyHex = publicKey.hex
        let timestamp = String(Date().timeIntervalSince1970)
        let signedTimestamp = try sign(message: timestamp)

        let challengeUrl = try buildUrl(method: "auth/challenge")

        var challengeRequest = URLRequest(url: challengeUrl)
        challengeRequest.httpMethod = "POST"
        challengeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        challengeRequest.setValue(pubKeyHex, forHTTPHeaderField: "Public-Key")
        challengeRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "timestamp": timestamp,
            "signature": signedTimestamp,
        ])

        let (challengeData, challengeResponse) = try await URLSession.shared.data(for: challengeRequest)

        guard let httpResponse = challengeResponse as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (challengeResponse as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: challengeData, encoding: .utf8) ?? ""
            Logger.error("Auth challenge failed: status=\(statusCode) body=\(body)", context: "RNBackup")
            throw RNBackupError.authFailed
        }

        let challengeResult = try JSONDecoder().decode(AuthChallengeResponse.self, from: challengeData)
        let signedChallenge = try sign(message: challengeResult.challenge)

        let authUrl = try buildUrl(method: "auth/response")
        var authRequest = URLRequest(url: authUrl)
        authRequest.httpMethod = "POST"
        authRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authRequest.setValue(pubKeyHex, forHTTPHeaderField: "Public-Key")
        authRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "signature": signedChallenge,
        ])

        let (authData, authResponse) = try await URLSession.shared.data(for: authRequest)

        guard let httpAuthResponse = authResponse as? HTTPURLResponse, httpAuthResponse.statusCode == 200 else {
            throw RNBackupError.authFailed
        }

        let bearerResult = try JSONDecoder().decode(AuthBearerResponse.self, from: authData)
        cachedBearer = bearerResult

        return bearerResult.bearer
    }

    private func sign(message: String) throws -> String {
        guard let secretKey else {
            throw RNBackupError.notSetup
        }

        let fullMessage = "\(Self.signedMessagePrefix)\(message)"
        return try Crypto.sign(message: fullMessage, privateKey: secretKey)
    }

    private func decrypt(_ blob: Data) throws -> Data {
        guard let encryptionKey else {
            throw RNBackupError.notSetup
        }

        guard blob.count > 28 else { // 12 nonce + 16 tag minimum
            throw RNBackupError.decryptFailed("Data too short")
        }

        let nonce = blob.prefix(12)
        let tag = blob.suffix(16)
        let ciphertext = blob.dropFirst(12).dropLast(16)

        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            return try AES.GCM.open(sealedBox, using: encryptionKey)
        } catch {
            throw RNBackupError.decryptFailed(error.localizedDescription)
        }
    }
}
