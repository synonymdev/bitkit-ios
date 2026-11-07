import SwiftUI

/// A contact opened during startup can use the restored session of its original wallet.
@MainActor
struct ContactScreenSession {
    private var owner: PubkyProfileManager.RemovalPresentationOwner
    private let admission: ProfileOperationAdmission
    private let wipe: WipeCoordinator
    private let wallet: UUID?
    private var displayedKey: String?

    init(profile: PubkyProfileManager, admission: ProfileOperationAdmission = .shared, wipe: WipeCoordinator? = nil) {
        let wipe = wipe ?? .shared
        self.admission = admission
        self.wipe = wipe
        owner = profile.removalPresentationOwner
        wallet = wipe.isGateUp ? nil : admission.walletForPresentation()
        displayedKey = profile.publicKeyForDisplay
    }

    mutating func restore(in profile: PubkyProfileManager) {
        if displayedKey == nil, profile.ownsRemovalPresentation(owner) {
            displayedKey = profile.publicKeyForDisplay
        }
        if let restored = profile.restoredRemovalPresentationOwner(from: owner),
           displayedKey == nil || PubkyPublicKeyFormat.matches(displayedKey, profile.publicKey)
        {
            owner = restored
        }
    }

    private var ownsWallet: Bool {
        guard let wallet, !wipe.isGateUp else { return false }
        return admission.walletForPresentation() == wallet
    }

    func owns(_ session: PubkyProfileManager.SignedInSession, in profile: PubkyProfileManager) -> Bool {
        ownsWallet && profile.currentSession == session
    }

    mutating func current(in profile: PubkyProfileManager, onSignedOut: () -> Void = {}) -> PubkyProfileManager.SignedInSession? {
        restore(in: profile)
        guard ownsWallet, !profile.isRestoringSession,
              profile.ownsRemovalPresentation(owner) else { return nil }
        guard let session = profile.currentSession else {
            onSignedOut()
            return nil
        }
        return session
    }
}

extension View {
    func contactScreenSession(_ session: Binding<ContactScreenSession?>, profile: PubkyProfileManager) -> some View {
        onChange(of: profile.isRestoringSession ? nil : profile.currentSession, initial: true) {
            if session.wrappedValue == nil {
                session.wrappedValue = ContactScreenSession(profile: profile)
            }
            session.wrappedValue?.restore(in: profile)
        }
        .onChange(of: profile.publicKeyForDisplay) {
            session.wrappedValue?.restore(in: profile)
        }
    }
}

extension AppViewModel {
    func showContactSignInRequired() {
        toast(type: .warning, title: t("pubky_auth__no_identity"))
    }
}
