import Foundation

func canRoutePubkyContactLink(
    isPaykitUIActive: Bool,
    isPubkyInitialized: Bool,
    hasLoadedContacts: Bool,
    hasSignedInIdentity: Bool
) -> Bool {
    !isPaykitUIActive || (isPubkyInitialized && (!hasSignedInIdentity || hasLoadedContacts))
}

@MainActor
func preparePubkyContactLink(
    profile: PubkyProfileManager,
    contacts: ContactsManager
) async throws -> Bool {
    guard profile.isInitialized, profile.initializationErrorMessage == nil,
          !profile.isDeletingProfile, !Task.isCancelled
    else { return false }
    guard profile.isAuthenticated else { return true }
    guard let session = profile.currentSession else { return false }
    do {
        try await contacts.refreshContacts(for: session.publicKey)
    } catch {
        guard !profile.isDeletingProfile, profile.currentSession == session, !Task.isCancelled else { return false }
        throw error
    }
    return !profile.isDeletingProfile && profile.currentSession == session && !Task.isCancelled
}

func pubkyContactPublicKeyForRouting(from url: URL, isPaykitUIActive: Bool) throws -> String? {
    guard isPaykitUIActive else { return nil }
    guard let publicKey = PubkyContactLink.publicKey(from: url) else {
        throw ContactsManagerError.invalidPublicKey
    }
    return publicKey
}

@MainActor
func routePublicContactIfSignedOut(publicKey: String, profile: PubkyProfileManager, navigation: NavigationViewModel) -> Bool {
    guard !profile.isAuthenticated else { return false }
    navigation.navigate(.addContact(publicKey: publicKey))
    return true
}

@MainActor
func prepareAndRoutePendingDeepLink(
    preparation: () async -> Void,
    routing: () async -> Void
) async {
    await preparation()
    guard !Task.isCancelled else { return }
    await routing()
}

enum PendingProfileSetupResumeState {
    case inactive
    case waiting
    case ready

    func shouldResume(didResume: inout Bool) -> Bool {
        if self == .inactive {
            didResume = false
        }
        guard self == .ready, !didResume else { return false }
        didResume = true
        return true
    }
}

func resolvePendingProfileSetupResumeState(
    isProfileSetupPending: Bool,
    isPaykitUIActive: Bool,
    isAuthenticated: Bool,
    hasActiveSheet: Bool,
    isReplacingSheet: Bool,
    currentRoute: Route?
) -> PendingProfileSetupResumeState {
    guard isProfileSetupPending else { return .inactive }
    guard isPaykitUIActive, isAuthenticated, !hasActiveSheet, !isReplacingSheet, currentRoute != .createProfile else {
        return .waiting
    }
    return .ready
}
