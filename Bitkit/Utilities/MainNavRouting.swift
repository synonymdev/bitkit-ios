import Foundation

func canRoutePubkyContactLink(
    isPaykitUIActive: Bool,
    isPubkyInitialized: Bool,
    hasLoadedContacts: Bool
) -> Bool {
    !isPaykitUIActive || (isPubkyInitialized && hasLoadedContacts)
}

func pubkyContactPublicKeyForRouting(from url: URL, isPaykitUIActive: Bool) throws -> String? {
    guard isPaykitUIActive else { return nil }
    guard let publicKey = PubkyContactLink.publicKey(from: url) else {
        throw ContactsManagerError.invalidPublicKey
    }
    return publicKey
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
