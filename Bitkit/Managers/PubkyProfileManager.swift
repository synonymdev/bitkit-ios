import Foundation
import Observation
import SwiftUI

enum PubkyAuthState: Equatable {
    case idle
    case authenticating
    case authenticated
    case error(String)
}

@MainActor
@Observable
class PubkyProfileManager {
    var authState: PubkyAuthState = .idle
    var profile: PubkyProfile?
    var publicKey: String?
    var isLoadingProfile = false
    var isInitialized = false
    private(set) var cachedName: String?
    private(set) var cachedImageUri: String?

    init() {
        cachedName = UserDefaults.standard.string(forKey: Self.cachedNameKey)
        cachedImageUri = UserDefaults.standard.string(forKey: Self.cachedImageUriKey)
    }

    // MARK: - Initialization & Session Restoration

    private enum InitResult: Sendable {
        case noSession
        case restored(publicKey: String)
        case restorationFailed
    }

    /// Initializes Paykit and restores any persisted session in a single off-main-actor pass.
    func initialize() async {
        let result: InitResult
        do {
            result = try await Task.detached {
                try await PubkyService.initialize()

                guard let savedSecret = try? Keychain.loadString(key: .paykitSession),
                      !savedSecret.isEmpty
                else {
                    return InitResult.noSession
                }

                do {
                    let pk = try await PubkyService.importSession(secret: savedSecret)
                    return InitResult.restored(publicKey: pk)
                } catch {
                    Logger.warn("Failed to restore paykit session: \(error)", context: "PubkyProfileManager")
                    try? Keychain.delete(key: .paykitSession)
                    return InitResult.restorationFailed
                }
            }.value
        } catch {
            Logger.error("Failed to initialize paykit: \(error)", context: "PubkyProfileManager")
            return
        }

        isInitialized = true

        switch result {
        case .noSession:
            Logger.debug("No saved paykit session found", context: "PubkyProfileManager")
        case let .restored(pk):
            publicKey = pk
            authState = .authenticated
            Logger.info("Paykit session restored for \(pk)", context: "PubkyProfileManager")
            Task { await loadProfile() }
        case .restorationFailed:
            break
        }
    }

    // MARK: - Auth Flow

    func cancelAuthentication() async {
        do {
            try await Task.detached {
                try await PubkyService.cancelAuth()
            }.value
        } catch {
            Logger.warn("Cancel auth failed: \(error)", context: "PubkyProfileManager")
        }
        authState = .idle
    }

    func startAuthentication() async throws {
        authState = .authenticating

        let authUrl: String
        do {
            authUrl = try await Task.detached {
                try await PubkyService.startAuth()
            }.value
        } catch {
            authState = .idle
            throw error
        }

        guard let url = URL(string: authUrl) else {
            authState = .idle
            throw PubkyServiceError.invalidAuthUrl
        }

        let canOpen = await UIApplication.shared.canOpenURL(url)
        guard canOpen else {
            authState = .idle
            throw PubkyServiceError.ringNotInstalled
        }

        await UIApplication.shared.open(url)
    }

    /// Long-polls the relay, persists + imports the session, and loads the profile in a single off-main-actor pass.
    func completeAuthentication() async throws {
        do {
            let pk = try await Task.detached {
                let sessionSecret = try await PubkyService.completeAuth()

                try? Keychain.delete(key: .paykitSession)
                guard let data = sessionSecret.data(using: .utf8) else {
                    throw PubkyServiceError.authFailed("Failed to encode session secret")
                }
                try Keychain.save(key: .paykitSession, data: data)

                return try await PubkyService.importSession(secret: sessionSecret)
            }.value

            publicKey = pk
            authState = .authenticated
            Logger.info("Pubky auth completed for \(pk)", context: "PubkyProfileManager")
            Task { await loadProfile() }
        } catch let serviceError as PubkyServiceError {
            authState = .idle
            throw serviceError
        } catch {
            authState = .error(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Profile

    func loadProfile() async {
        guard let pk = publicKey, !isLoadingProfile else { return }

        isLoadingProfile = true

        do {
            let loadedProfile = try await Task.detached {
                let profileDto = try await PubkyService.getProfile(publicKey: pk)
                Logger.debug("Profile loaded — name: \(profileDto.name), image: \(profileDto.image ?? "nil")", context: "PubkyProfileManager")
                return PubkyProfile(publicKey: pk, ffiProfile: profileDto)
            }.value
            profile = loadedProfile
            cacheProfileMetadata(loadedProfile)
        } catch {
            Logger.error("Failed to load profile: \(error)", context: "PubkyProfileManager")
        }

        isLoadingProfile = false
    }

    // MARK: - Sign Out

    func signOut() async {
        await Task.detached {
            do {
                try await PubkyService.signOut()
            } catch {
                Logger.warn("Server sign out failed, forcing local sign out: \(error)", context: "PubkyProfileManager")
                await PubkyService.forceSignOut()
            }
            try? Keychain.delete(key: .paykitSession)
            PubkyImageCache.shared.clear()
        }.value

        clearCachedProfileMetadata()
        publicKey = nil
        profile = nil
        authState = .idle
    }

    // MARK: - Cached Profile Metadata

    private static let cachedNameKey = "pubky_profile_name"
    private static let cachedImageUriKey = "pubky_profile_image_uri"

    var displayName: String? {
        profile?.name ?? cachedName
    }

    var displayImageUri: String? {
        profile?.imageUrl ?? cachedImageUri
    }

    private func cacheProfileMetadata(_ profile: PubkyProfile) {
        cachedName = profile.name
        cachedImageUri = profile.imageUrl
        UserDefaults.standard.set(profile.name, forKey: Self.cachedNameKey)
        UserDefaults.standard.set(profile.imageUrl, forKey: Self.cachedImageUriKey)
    }

    private func clearCachedProfileMetadata() {
        cachedName = nil
        cachedImageUri = nil
        UserDefaults.standard.removeObject(forKey: Self.cachedNameKey)
        UserDefaults.standard.removeObject(forKey: Self.cachedImageUriKey)
    }

    // MARK: - Helpers

    var isAuthenticated: Bool {
        authState == .authenticated
    }
}
