import Combine
import Foundation
import enum Paykit.PaykitError
import struct Paykit.PaykitProfileRecord
import struct Paykit.PubkySessionBootstrapResult
import SwiftUI

enum PubkyAuthState: Equatable {
    case idle
    case authenticated
}

private enum PubkyProfileManagerError: LocalizedError {
    case avatarEncodingFailed

    var errorDescription: String? {
        switch self {
        case .avatarEncodingFailed:
            return "Failed to encode avatar image"
        }
    }
}

enum PubkySignupError: Error {
    case alreadySignedIn
    case inProgress
}

/// Counts the choice-screen loads still waiting on one Ring row lookup, starting with the load that started it. A load
/// leaves from its cancellation handler, which runs off the main actor, so the count is locked.
private final class RingIdentityLookupLoaders: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 1

    /// Fails once every load has left, since the lookup is then being cancelled.
    func join() -> Bool {
        lock.withLock {
            guard count > 0 else { return false }
            count += 1
            return true
        }
    }

    /// True for the last load to leave, which cancels the lookup.
    func leave() -> Bool {
        lock.withLock {
            count -= 1
            return count == 0
        }
    }
}

@MainActor
class PubkyProfileManager: ObservableObject {
    enum SessionInitializationResult: Equatable {
        case noSession
        case restored(publicKey: String)
        case restorationDeferred
        case restorationFailed
    }

    typealias RemoteProfileResolver = @Sendable (String) async throws -> PubkyProfile
    typealias ProfilePublisher = @Sendable (_ profile: PubkyProfileData, _ expectedIdentity: String?) async throws -> Void
    typealias AvatarUploader = @Sendable (_ jpegData: Data, _ expectedIdentity: String?) async throws -> String

    enum RemovalAction: Equatable {
        case deleteProfile
        case unlink
        case disconnect
        case disconnectLocally
    }

    struct RemovalConfirmation: Identifiable, Equatable {
        let id: UUID
        let action: RemovalAction
    }

    struct RemovalPresentationOwner: Equatable {
        fileprivate let revision: UUID
        fileprivate let publicKey: String?
    }

    var removalPresentationOwner: RemovalPresentationOwner {
        RemovalPresentationOwner(revision: Self.sessionRevision, publicKey: publicKey)
    }

    func ownsRemovalPresentation(_ owner: RemovalPresentationOwner) -> Bool {
        removalPresentationOwner == owner && !removalAdmission.isWalletWiping
    }

    /// A failed, reconciled transition can return its own new session revision to the original screen.
    /// A successor invalidates the supplied scope before any retry context is installed.
    func schedulePresentationContext(_ update: @escaping @MainActor (RemovalPresentationOwner, ProfileOperationAdmission.Generation) -> Void) throws {
        let owner = removalPresentationOwner
        let admission = removalAdmission
        try admission.checkCurrent()
        try admission.scheduleAfterTransition { scope in
            Task { @MainActor [weak self] in
                defer { admission.release(scope) }
                guard let self, ownsRemovalPresentation(owner), (try? admission.validate(scope)) != nil,
                      let generation = try? admission.snapshot() else { return }
                update(owner, generation)
            }
        }
    }

    func ownsRemovalFailure(_ confirmation: RemovalConfirmation, owner: RemovalPresentationOwner) -> Bool {
        guard !removalAdmission.isWalletWiping else { return false }
        if ownsRemovalPresentation(owner) {
            return true
        }
        // Strict local teardown ends the session before fallible durable cleanup. Its exact pending attempt
        // still owns failure presentation, without granting any remote retry authority.
        guard case let .pending(record) = removalRecovery else { return false }
        return record.id == confirmation.id && record.scope == .profile
    }

    func ownsRecoveryFailure(id: UUID, scope: ProfileRemovalStore.Scope) -> Bool {
        guard !isDeletingProfile, !removalAdmission.isWalletWiping, case let .pending(record) = removalRecovery else { return false }
        return record.id == id && record.scope == scope
    }

    struct RemovalCompletion {
        let remoteProfileDeleted: Bool
        fileprivate let endedRevision: UUID
        fileprivate let admissionGeneration: ProfileOperationAdmission.Generation
    }

    enum RemovalError: Error {
        case confirmationRequired
        case confirmationChanged
    }

    struct RemovalServices {
        var readProfile: @Sendable (String) async throws -> PaykitProfileRecord?
        var deleteProfile: @Sendable (String, String) async throws -> Void
        var withdrawPrivate: @MainActor () async throws -> Void
        var withdrawPublic: @MainActor () async throws -> Void
        var validateSubscriptions: @MainActor (String) async throws -> Void
        var captureRevocation: @MainActor (String) async throws -> ProfileSessionRevocation
        var completeLocal: @MainActor () async throws -> Void
        var completeRevokedLocal: @MainActor (ProfileSessionRevocation) async throws -> Void
        var pause: @MainActor (UUID) async -> Void
        var resume: @MainActor (UUID) async -> Void

        @MainActor static var live: RemovalServices {
            RemovalServices(
                readProfile: { try await PaykitSdkService.shared.profileRemovalRecord(publicKey: $0) },
                deleteProfile: { try await PaykitSdkService.shared.deleteConfirmedProfile(expectedIdentity: $0, expectedRevision: $1) },
                withdrawPrivate: { try await removePrivatePaykitEndpoints(context: "Profile removal", deferAppSync: true) },
                withdrawPublic: {
                    try await PublicPaykitService.removePublishedEndpoints()
                    try await PublicPaykitService.syncPaykitApp(privateSharingEnabled: false)
                },
                validateSubscriptions: { try await PaykitSdkService.shared.requireNoActiveSubscriptions(expectedIdentity: $0) },
                captureRevocation: { try await PaykitSdkService.shared.captureProfileRevocation(expectedOwner: $0) },
                completeLocal: { try await clearLocalState() },
                completeRevokedLocal: { try await clearLocalState(forgetSessionAccess: $0.clearCredentials) },
                pause: { await PrivatePaykitService.shared.beginProfileDeletion(id: $0) },
                resume: { await PrivatePaykitService.shared.endProfileDeletion(id: $0) }
            )
        }
    }

    private let removalServices: RemovalServices
    private let removalAdmission: ProfileOperationAdmission
    private let sourceIsMissing: (String, String) -> Bool
    #if DEBUG
        var beforeCommittedIdentityInstallForTesting: (() async -> Void)?
    #endif
    private let removalStore: ProfileRemovalStore

    private struct RemovalPlan {
        let confirmation: RemovalConfirmation
        let sessionRevision: UUID
        let owner: String?
        let profileGeneration: Int
        let admissionGeneration: ProfileOperationAdmission.Generation
        let profile: PaykitProfileRecord?
        let withdrawEndpoints: Bool
        let contacts: ContactsManager?
        let contactSnapshot: ContactsManager.RemovalSnapshot?
        let revocation: ProfileSessionRevocation?
    }

    struct RemoteRemovalConfirmation: Identifiable, Equatable {
        let id: UUID
        let removalID: UUID
    }

    private final class LiveRemoval {
        let plan: RemovalPlan
        let lease: ProfileRemovalLease
        var privateAcknowledged = false
        var publicAcknowledged = false
        var remoteProfileDeleted = false
        var logoutStarted = false
        var logoutAcknowledged = false

        init(plan: RemovalPlan, lease: ProfileRemovalLease) {
            self.plan = plan
            self.lease = lease
        }
    }

    private var liveRemoval: LiveRemoval?
    private var remoteRemovalConfirmation: RemoteRemovalConfirmation?

    private var removalPreparation: UUID?
    private var removalPlan: RemovalPlan?
    private var failedRemovalID: UUID?

    private enum SessionInitializationMode {
        case userVisible
        case automaticRecovery
    }

    /// A remote read of the signed-in profile. It applies its result only while `profileWriteGeneration` still equals
    /// `generation`.
    private struct ProfileRead {
        enum Kind {
            case load
            case reusedRingProfileRefresh(adoptionRevision: UUID)
        }

        let id = UUID()
        let kind: Kind
        let publicKey: String
        let generation: Int
    }

    enum RemovalRecovery: Equatable {
        case ready
        case pending(ProfileRemovalStore.Pending)
        case unavailable

        var blocksWalletStartup: Bool {
            switch self {
            case .ready: false
            case let .pending(record): record.scope == .walletWipe
            case .unavailable: true
            }
        }
    }

    @Published private(set) var removalRecovery: RemovalRecovery = .ready
    private var removalChanges: AnyCancellable?

    @Published var authState: PubkyAuthState = .idle
    @Published var profile: PubkyProfile?
    @Published var publicKey: String?
    @Published private var readOnlyProfile: (publicKey: String, profile: PubkyProfile?, revision: UUID)?
    @Published var isLoadingProfile = false
    @Published private(set) var isRestoringSession = false
    @Published private(set) var isDeletingProfile = false
    @Published var isInitialized = false
    @Published var initializationErrorMessage: String?
    @Published var sessionRestorationFailed = false
    @Published var adoptedSourceLost = false
    @Published private(set) var cachedName: String?
    @Published private(set) var cachedImageUri: String?
    /// The pubky the cached name and avatar were written for. Nil for a cache written before the owner was stored.
    @Published private var cachedProfileOwner: String?
    @Published private(set) var isProfileSetupPending: Bool
    /// Public profiles found for the Pubky Ring rows on the choice screen, keyed by normalized pubky. Display-only.
    @Published private(set) var ringIdentityProfiles: [String: PubkyProfile] = [:]
    /// Ring rows whose lookup is still running, keyed like `ringIdentityProfiles`. A stopped lookup leaves without waiting
    /// for its task to end.
    @Published private(set) var ringIdentityLookupsInFlight: Set<String> = []
    /// Covers a Ring adoption from before its reference is written, which already makes `hasExistingIdentity` true, until
    /// it succeeds, fails or is cancelled.
    @Published private(set) var isAdoptingRingIdentity = false

    private var isSignupInFlight = false
    private var initializationTask: Task<Void, Never>?
    private var initializationRevision: UUID?
    private var restoreInitialization: (id: UUID, revision: UUID, task: Task<Void, Never>)?
    private var completedRecoveryVersion = 0
    private var sessionRestorationDeferred = false
    private var readOnlySignOutRevision: UUID?
    private var savedIdentityLookup: (revision: UUID, exists: Bool)?
    private static var isRingAdoptionInFlight = false
    private static var sessionRevision = UUID()
    private static var sessionMutationCount = 0
    private static var isProfileDeletionInFlight = false
    private let remoteProfileResolver: RemoteProfileResolver
    private let profilePublisher: ProfilePublisher
    private let avatarUploader: AvatarUploader
    /// Bumped whenever a profile save starts, `profile` is written or the identity changes, so a remote read that started
    /// earlier is dropped.
    private var profileWriteGeneration = 0
    /// The last profile read started, until it ends. Only a read whose result can still apply holds back another, so a
    /// read that a write dropped never stops the read that replaces it.
    private var profileReadInFlight: ProfileRead?
    /// Profile saves started and not returned yet.
    private var profileSavesInFlight = 0
    /// A profile read a save dropped, with the session it was for, which runs again once the last save in flight fails.
    /// A published profile makes it moot.
    private var profileReadAwaitingSaves: (read: ProfileRead, session: SignedInSession)?
    /// Ring rows whose lookup found nothing. The SDK reports a missing record and an offline failure alike, so a miss
    /// only stops repeat lookups and must never drive sign-up or profile-setup decisions.
    private var ringIdentityMisses: Set<String> = []
    private typealias RingIdentityLookup = (id: UUID, task: Task<Void, Never>, loaders: RingIdentityLookupLoaders)
    private var ringIdentityLookups: [String: RingIdentityLookup] = [:]

    private static func beginSessionMutation(allowDuringProfileDeletion: Bool = false) throws {
        guard !isProfileDeletionInFlight || allowDuringProfileDeletion else { throw PubkyServiceError.identityChanged }
        sessionRevision = UUID()
        sessionMutationCount += 1
    }

    private static func endSessionMutation() {
        sessionMutationCount -= 1
        if sessionMutationCount == 0 {
            sessionSettledSubject.send()
        }
    }

    private static let sessionSettledSubject = PassthroughSubject<Void, Never>()

    /// Fires when the last session change in flight ends. `currentSession` reads nil until then, and nothing published
    /// changes at that moment, so work that needs the session (a sign-in completing during that change) waits for this.
    static var sessionSettledPublisher: AnyPublisher<Void, Never> {
        sessionSettledSubject.eraseToAnyPublisher()
    }

    init(
        remoteProfileResolver: @escaping RemoteProfileResolver = { try await PubkyProfileManager.resolveRemoteProfile(publicKey: $0) },
        profilePublisher: @escaping ProfilePublisher = {
            try await PubkyService.publishPaykitProfile($0.toPaykitProfile(), expectedIdentity: $1)
        },
        avatarUploader: @escaping AvatarUploader = {
            try await PubkyService.uploadProfileAvatar(bytes: $0, contentType: "image/jpeg", expectedIdentity: $1)
        },
        removalServices: RemovalServices? = nil,
        removalStore: ProfileRemovalStore = .shared,
        removalAdmission: ProfileOperationAdmission = .shared,
        sourceIsMissing: @escaping (String, String) -> Bool = { SharedPubkyKeychain.isDefinitelyMissing(sourceApp: $0, pubky: $1) }
    ) {
        self.removalServices = removalServices ?? .live
        self.removalStore = removalStore
        self.removalAdmission = removalAdmission
        self.sourceIsMissing = sourceIsMissing
        self.remoteProfileResolver = remoteProfileResolver
        self.profilePublisher = profilePublisher
        self.avatarUploader = avatarUploader
        cachedName = UserDefaults.standard.string(forKey: Self.cachedNameKey)
        cachedImageUri = UserDefaults.standard.string(forKey: Self.cachedImageUriKey)
        cachedProfileOwner = UserDefaults.standard.string(forKey: Self.cachedProfileOwnerKey)
        isProfileSetupPending = UserDefaults.standard.bool(forKey: Self.profileSetupPendingKey)
        refreshRemovalRecovery()
        removalChanges = NotificationCenter.default.publisher(for: ProfileRemovalStore.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshRemovalRecovery() }
    }

    func refreshRemovalRecovery() {
        do {
            guard !removalAdmission.hasUnpersistedLocalFailure else { throw ProfileRemovalStore.StoreError.unavailable }
            removalRecovery = try removalStore.pending().map(RemovalRecovery.pending) ?? .ready
        } catch {
            removalRecovery = .unavailable
        }
        if removalRecovery != .ready {
            isInitialized = true
            isRestoringSession = false
        }
    }

    func retryLocalRecoveryRecord() {
        do {
            try removalAdmission.persistLocalFailure(recoverMalformed: true)
            try removalStore.recoverMalformedRecord()
        } catch { initializationErrorMessage = error.localizedDescription }
        refreshRemovalRecovery()
    }

    var hasExistingIdentity: Bool {
        if isAuthenticated || cachedName != nil {
            return true
        }
        if Self.sessionMutationCount == 0, let savedIdentityLookup, savedIdentityLookup.revision == Self.sessionRevision {
            return savedIdentityLookup.exists
        }
        // Unreadable credentials must not be treated as a new identity.
        return (try? Self.hasStoredIdentity()) != false
    }

    func hasExistingIdentityForNavigation(
        hasStoredIdentity: @escaping @Sendable () throws -> Bool = { try PubkyProfileManager.hasStoredIdentity() }
    ) async -> Bool {
        if isAuthenticated || cachedName != nil {
            return true
        }
        let revision = Self.sessionRevision
        let canCacheLookup = Self.sessionMutationCount == 0
        let exists = await Task.detached {
            // Unreadable credentials must not offer identity creation.
            (try? hasStoredIdentity()) != false
        }.value
        if canCacheLookup, Self.sessionMutationCount == 0, revision == Self.sessionRevision {
            savedIdentityLookup = (revision, exists)
        }
        return isAuthenticated || cachedName != nil || exists
    }

    // MARK: - Initialization & Session Restoration

    /// Initializes Paykit and restores any persisted session.
    func initialize(
        initializeSession: @escaping @Sendable () async throws -> SessionInitializationResult = {
            try await PubkyProfileManager.initializePersistedSession()
        }
    ) async {
        await initialize(mode: .userVisible, initializeSession: initializeSession)
    }

    func scheduleInitializationAfterRestore(
        initializeSession: @escaping @Sendable () async throws -> SessionInitializationResult = {
            try await PubkyProfileManager.initializePersistedSession()
        }
    ) {
        let revision = Self.sessionRevision
        guard restoreInitialization?.revision != revision, Self.sessionMutationCount == 0, !Self.isProfileDeletionInFlight else { return }
        clearAuthenticatedState(clearCachedProfile: false)
        let previousRevision = initializationRevision
        let initialization = beginInitialization(mode: .userVisible, initializeSession: initializeSession)
        let id = UUID()
        let task = Task {
            defer {
                if restoreInitialization?.id == id {
                    restoreInitialization = nil
                }
            }
            guard revision == Self.sessionRevision else { return }
            await initialization?.value
            guard revision == Self.sessionRevision else { return }
            if let previousRevision, previousRevision != revision {
                await initialize(mode: .userVisible, initializeSession: initializeSession)
            }
        }
        restoreInitialization = (id, revision, task)
    }

    private func initialize(
        mode: SessionInitializationMode,
        initializeSession: @escaping @Sendable () async throws -> SessionInitializationResult
    ) async {
        await beginInitialization(mode: mode, initializeSession: initializeSession)?.value
    }

    private func beginInitialization(
        mode: SessionInitializationMode,
        initializeSession: @escaping @Sendable () async throws -> SessionInitializationResult
    ) -> Task<Void, Never>? {
        if let initializationTask {
            return initializationTask
        }
        guard Self.sessionMutationCount == 0, !Self.isProfileDeletionInFlight else { return nil }
        refreshRemovalRecovery()
        guard removalRecovery == .ready else { return nil }
        let admission = removalAdmission
        let scope: ProfileOperationAdmission.Scope
        do { scope = try admission.reserveSessionTransition(backgroundInitialization: true) }
        catch {
            refreshRemovalRecovery()
            isInitialized = true
            initializationErrorMessage = error.localizedDescription
            return nil
        }
        isRestoringSession = true
        let revision = Self.sessionRevision
        let task = Task {
            var releaseOriginal = true
            var missingSource: MissingAdoptedSource?
            defer {
                if releaseOriginal {
                    admission.release(scope)
                }
                initializationTask = nil
                initializationRevision = nil
                isRestoringSession = false
            }
            guard revision == Self.sessionRevision, Self.sessionMutationCount == 0, !Self.isProfileDeletionInFlight else { return }
            do {
                try await admission.withScope(scope, access: .control) {
                    try await admission.drain(before: scope)
                    missingSource = confirmedMissingSource()
                    if missingSource == nil {
                        await initializeSessionState(mode: mode, initializeSession: initializeSession)
                        missingSource = confirmedMissingSource()
                    }
                    try admission.checkCurrent()
                    if case .automaticRecovery = mode, revision == Self.sessionRevision {
                        completedRecoveryVersion += 1
                    }
                }
                if let missingSource {
                    let id = UUID()
                    let recovery = try admission.handoffToLocalRecovery(from: scope, id: id)
                    admission.release(scope)
                    releaseOriginal = false
                    let completion = try await runRemoval(scope: recovery, id: id, plan: nil) { try self.requireMissingSource(missingSource) }
                    if ownsRemovalCompletion(completion) {
                        adoptedSourceLost = true
                    }
                    isInitialized = true
                }
            } catch {
                initializationErrorMessage = error.localizedDescription
                refreshRemovalRecovery()
                isInitialized = true
            }
        }
        initializationTask = task
        initializationRevision = revision
        return task
    }

    /// Retry saved credentials after startup or connectivity failures without replacing active identity work.
    func restoreSessionIfNeeded(
        hasStoredIdentity: () throws -> Bool = { try PubkyProfileManager.hasStoredIdentity() },
        initializeSession: @escaping @Sendable () async throws -> SessionInitializationResult = {
            try await PubkyProfileManager.initializePersistedSession()
        }
    ) async {
        let recoveryVersion = completedRecoveryVersion
        let revision = Self.sessionRevision
        if let initializationTask {
            await initializationTask.value
        }
        if completedRecoveryVersion != recoveryVersion, revision == Self.sessionRevision {
            return
        }
        refreshRemovalRecovery()
        guard removalRecovery == .ready, !Task.isCancelled else { return }
        if let session = automaticPaykitSession {
            if isInitialized, profile == nil {
                Task {
                    guard automaticPaykitSession == session, isInitialized, profile == nil else { return }
                    await loadProfile()
                }
            }
            return
        }
        guard publicKey == nil, authState == .idle, Self.sessionMutationCount == 0 else { return }
        do {
            guard try hasStoredIdentity() else { return }
            await initialize(mode: .automaticRecovery, initializeSession: initializeSession)
        } catch {
            Logger.warn("Unable to read saved Pubky identity for recovery: \(error)", context: "PubkyProfileManager")
        }
    }

    func retrySessionRestoration(
        retryDelay: Duration = .seconds(10),
        jitter: () -> Double = { Double.random(in: 0.8 ... 1.2) },
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        hasStoredIdentity: () throws -> Bool = { try PubkyProfileManager.hasStoredIdentity() },
        initializeSession: @escaping @Sendable () async throws -> SessionInitializationResult = {
            try await PubkyProfileManager.initializePersistedSession()
        }
    ) async {
        // A usable connection can return without a new network-path event.
        let maximumDelay = Duration.seconds(180)
        let revision = Self.sessionRevision
        var delay = retryDelay
        var deferredRetries = 0
        while !Task.isCancelled, revision == Self.sessionRevision {
            await restoreSessionIfNeeded(hasStoredIdentity: hasStoredIdentity, initializeSession: initializeSession)
            guard removalRecovery == .ready, !Task.isCancelled, revision == Self.sessionRevision,
                  !isAuthenticated, (try? hasStoredIdentity()) != false
            else { return }
            let nextDelay: Duration
            if sessionRestorationDeferred, deferredRetries < 8 {
                deferredRetries += 1
                nextDelay = min(retryDelay, .seconds(5))
            } else {
                nextDelay = delay
                delay = min(delay * 2, maximumDelay)
            }
            do {
                try await sleep(min(nextDelay * jitter(), maximumDelay))
            } catch {
                return
            }
        }
    }

    private func initializeSessionState(
        mode: SessionInitializationMode,
        initializeSession: @escaping @Sendable () async throws -> SessionInitializationResult
    ) async {
        let revision = Self.sessionRevision
        if case .userVisible = mode {
            isInitialized = false
            initializationErrorMessage = nil
            sessionRestorationFailed = false
        }

        let result: SessionInitializationResult
        do {
            let initialized = try await removalAdmission.withDetached {
                try await initializeSession()
            }
            try removalAdmission.checkCurrent()
            result = initialized
        } catch {
            guard revision == Self.sessionRevision else {
                isInitialized = true
                return
            }
            if Self.isTemporarySessionRestorationError(error) {
                result = .restorationDeferred
            } else {
                Logger.error("Failed to initialize paykit: \(error)", context: "PubkyProfileManager")
                authState = .idle
                sessionRestorationDeferred = false
                readOnlyProfile = nil
                if case .userVisible = mode {
                    initializationErrorMessage = error.localizedDescription
                }
                return
            }
        }

        guard revision == Self.sessionRevision else {
            isInitialized = true
            return
        }
        guard confirmedMissingSource() == nil else { return }
        initializationErrorMessage = nil
        Self.publishOwnSharedRecord()

        switch result {
        case .noSession:
            sessionRestorationDeferred = false
            clearAuthenticatedState()
            sessionRestorationFailed = false
            Logger.debug("No saved paykit session found", context: "PubkyProfileManager")
        case let .restored(pk):
            sessionRestorationDeferred = false
            invalidateProfileLoads()
            if !hasReadOnlyProfileIdentity || !PubkyPublicKeyFormat.matches(readOnlyProfile?.publicKey, pk) {
                readOnlyProfile = nil
            }
            reloadCachedProfileMetadata()
            publicKey = pk
            authState = .authenticated
            sessionRestorationFailed = false
            Logger.info("Paykit session restored for \(pk)", context: "PubkyProfileManager")
            scheduleProfileRead { await self.loadProfile() }
        case .restorationFailed:
            sessionRestorationDeferred = false
            clearAuthenticatedState(clearCachedProfile: false)
            if case .userVisible = mode {
                sessionRestorationFailed = true
            }
        case .restorationDeferred:
            clearAuthenticatedState(clearCachedProfile: false, clearReadOnlyProfile: false)
            sessionRestorationFailed = false
            sessionRestorationDeferred = true
        }

        isInitialized = true
    }

    private struct MissingAdoptedSource {
        let sourceApp: String
        let publicKey: String
        let revision: UUID
    }

    private func confirmedMissingSource() -> MissingAdoptedSource? {
        guard let adopted = AdoptedPubkyReference.current,
              sourceIsMissing(adopted.sourceApp, adopted.pubky) else { return nil }
        return MissingAdoptedSource(sourceApp: adopted.sourceApp, publicKey: adopted.pubky, revision: Self.sessionRevision)
    }

    private func requireMissingSource(_ expected: MissingAdoptedSource) throws {
        guard let current = confirmedMissingSource(), current.sourceApp == expected.sourceApp,
              current.publicKey == expected.publicKey, current.revision == expected.revision
        else {
            throw ProfileRemovalStore.StoreError.changed
        }
    }

    /// A definitely removed Ring source ends only this captured local session, with the same durable cleanup rules.
    func checkAdoptedSource() async {
        guard !Self.isProfileDeletionInFlight, let expected = confirmedMissingSource() else { return }
        let admission = removalAdmission
        do {
            let scope = try admission.reserveSessionTransition(backgroundInitialization: true)
            var releaseOriginal = true
            defer {
                if releaseOriginal {
                    admission.release(scope)
                }
            }
            try await admission.withScope(scope, access: .control) {
                try await admission.drain(before: scope)
                try requireMissingSource(expected)
            }
            let id = UUID()
            let recovery = try admission.handoffToLocalRecovery(from: scope, id: id)
            admission.release(scope)
            releaseOriginal = false
            let completion = try await runRemoval(scope: recovery, id: id, plan: nil) { try self.requireMissingSource(expected) }
            if ownsRemovalCompletion(completion) {
                adoptedSourceLost = true
            }
        } catch {
            refreshRemovalRecovery()
            initializationErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Key Derivation & Identity Creation

    /// Derive the Pubky keypair from the wallet's BIP39 seed.
    /// Returns (publicKeyZ32, secretKeyHex).
    func deriveKeys() async throws -> (String, String) {
        return try await ProfileOperationAdmission.shared.withOperation {
            return try await ProfileOperationAdmission.shared.withDetached {
                let secretKeyHex = try Self.deriveLocalSecretKeyFromWalletSeed()
                let rawKey = try PubkyService.pubkyPublicKeyFromSecret(secretKeyHex: secretKeyHex)
                let publicKeyZ32 = rawKey.hasPrefix("pubky") ? rawKey : "pubky\(rawKey)"
                return (publicKeyZ32, secretKeyHex)
            }
        }
    }

    /// The public key of the identity in use: the adopted pubky when one exists, otherwise the wallet-derived one.
    func activePublicKey() async throws -> String {
        return try await ProfileOperationAdmission.shared.withOperation {
            if let adopted = AdoptedPubkyReference.current,
               let publicKey = PubkyPublicKeyFormat.normalized(adopted.pubky)
            {
                return publicKey
            }

            return try await deriveKeys().0
        }
    }

    /// Fetch a signup code and homeserver public key from Homegate's IP verification endpoint.
    struct HomegateResponse: Decodable {
        let signupCode: String
        let homeserverPubky: String
    }

    private static func fetchHomegateSignupCode() async throws -> HomegateResponse {
        let url = URL(string: "\(Env.homegateUrl)/ip_verification")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw PubkyServiceError.authFailed("Homegate returned status \(statusCode)")
        }

        let decoder = JSONDecoder()
        return try decoder.decode(HomegateResponse.self, from: data)
    }

    /// Upload an avatar image to the user's homeserver blob storage. Returns the `pubky://` URI. With `expectedIdentity`,
    /// the upload writes nothing and throws `identityChanged` unless that identity is still signed in when it runs.
    func uploadAvatar(image: UIImage, expectedIdentity: String? = nil) async throws -> String {
        return try await ProfileOperationAdmission.shared.withOperation {
            _ = try activeSessionSecret()
            let imageData = try compressAvatar(image)
            return try await avatarUploader(imageData, expectedIdentity)
        }
    }

    private func compressAvatar(_ image: UIImage, maxSize: CGFloat = 400) throws -> Data {
        // Resize to max dimensions
        let scale = min(maxSize / image.size.width, maxSize / image.size.height, 1.0)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }

        guard let jpegData = resized.jpegData(compressionQuality: 0.8) else {
            throw PubkyProfileManagerError.avatarEncodingFailed
        }
        return jpegData
    }

    nonisolated static func resolvedImageUrl(newImageUrl: String?, existingImageUrl: String?) -> String? {
        newImageUrl ?? existingImageUrl
    }

    func createIdentity(
        name: String,
        bio: String,
        links: [PubkyProfileLink],
        tags: [String] = [],
        existingImageUrl: String? = nil,
        avatarImage: UIImage? = nil,
        loadStoredSecretKey: () async throws -> String? = {
            await Task.detached { PubkyProfileManager.activeSecretKeyHex() }.value
        }
    ) async throws {
        return try await ProfileOperationAdmission.shared.withSessionTransition {
            try Self.beginSessionMutation()
            defer { Self.endSessionMutation() }
            if let publicKey, isProfileSetupPending || AdoptedPubkyReference.current != nil {
                try await createProfile(
                    publicKey: publicKey,
                    name: name,
                    bio: bio,
                    links: links,
                    tags: tags,
                    existingImageUrl: existingImageUrl,
                    avatarImage: avatarImage
                )
                return
            }

            setProfileSetupPending(false)
            var attempt: PaykitSdkService.CredentialAttempt?
            var preparedProfile: PubkyProfile?
            var acknowledged = false
            do {
                try await Self.completeIdentityCreation(
                    loadStoredSecretKey: loadStoredSecretKey,
                    signIn: { secretKeyHex in
                        try await ProfileOperationAdmission.shared.withDetached {
                            _ = try await PubkyService.signIn(secretKeyHex: secretKeyHex)
                            return try Self.publicKeyFromSecretKey(secretKeyHex)
                        }
                    },
                    signUp: {
                        attempt = try await PaykitSdkService.shared.beginCredentialAttempt()
                        let (publicKey, secretKeyHex) = try await self.deriveKeys()
                        _ = try await ProfileOperationAdmission.shared.withDetached {
                            try await Self.signUpOrSignIn(
                                signUp: { try await Self.signUpToHomeserver(secretKeyHex: secretKeyHex) },
                                signIn: { try await PubkyService.signIn(secretKeyHex: secretKeyHex) }
                            )
                        }
                        return publicKey
                    },
                    createProfile: { publicKey in
                        preparedProfile = try await self.createProfile(
                            publicKey: publicKey,
                            name: name,
                            bio: bio,
                            links: links,
                            tags: tags,
                            existingImageUrl: existingImageUrl,
                            avatarImage: avatarImage,
                            installsProfile: attempt == nil
                        )
                    },
                    discardSessionAccess: {}
                )
                if let attempt {
                    let activation = try await PaykitSdkService.shared.commitCredentialAttempt(attempt)
                    acknowledged = true
                    #if DEBUG
                        await beforeCommittedIdentityInstallForTesting?()
                    #endif
                    try ProfileOperationAdmission.shared.validateAcknowledgedLocalCompletion()
                    Self.applyCommittedActivation(activation)
                    if let preparedProfile {
                        installCreatedProfile(preparedProfile)
                    }
                }
            } catch {
                if let attempt, !acknowledged {
                    do {
                        try await Task.detached { try await PaykitSdkService.shared.rollbackCredentialAttempt(attempt) }.value
                    } catch {
                        refreshRemovalRecovery()
                        initializationErrorMessage = error.localizedDescription
                        Logger.error("New identity requires local recovery: \(error)", context: "PubkyProfileManager")
                    }
                }
                throw error
            }
            Self.publishOwnSharedRecord()
        }
    }

    static func applyCommittedActivation(_ activation: PaykitSdkService.CredentialActivation?) {
        guard let activation else { return }
        activateCachedIdentity(publicKey: activation.publicKey, previousPublicKey: activation.previousPublicKey)
        if activation.removesOwnSharedRecord {
            SharedPubkyKeychain.removeAllOwn()
        }
    }

    /// Publishes Bitkit's own pubky into the shared keychain group so Pubky Ring can offer it. Best effort.
    nonisolated static func publishOwnSharedRecord() {
        let admission = ProfileOperationAdmission.shared
        do {
            try admission.withSynchronousOperation {
                guard let secretKeyHex = try Keychain.loadString(key: .pubkySecretKey), !secretKeyHex.isEmpty else { return }
                let pubky = try SharedPubkyKeychain.derivedPubky(fromSecretKeyHex: secretKeyHex)
                try admission.checkCurrent()
                SharedPubkyKeychain.publishOwn(pubky: pubky, secretKeyHex: secretKeyHex)
            }
        } catch {
            Logger.warn("Failed to publish the shared pubky record: \(error)", context: "PubkyProfileManager")
        }
    }

    private nonisolated static func isUnpublishedIdentity(publicKey: String) async -> Bool {
        do {
            return try await !PubkyService.hasIdentityRecord(publicKey: publicKey)
        } catch {
            Logger.warn("Failed to check the Pubky Ring key's identity record: \(error)", context: "PubkyProfileManager")
            return false
        }
    }

    private nonisolated static func signUpToHomeserver(secretKeyHex: String) async throws -> String {
        let signupDetails: (homeserverPubky: String, signupCode: String?)
        if let homeserverPubky = Env.e2eHomeserverPubky {
            signupDetails = (homeserverPubky, nil)
        } else {
            let homegate = try await fetchHomegateSignupCode()
            signupDetails = (homegate.homeserverPubky, homegate.signupCode)
        }

        return try await PubkyService.signUp(
            secretKeyHex: secretKeyHex,
            homeserverZ32: signupDetails.homeserverPubky,
            signupCode: signupDetails.signupCode
        )
    }

    nonisolated static func signUpOrSignIn(
        signUp: () async throws -> String, signIn: () async throws -> String
    ) async throws -> String {
        do { return try await signUp() }
        catch is CancellationError { throw CancellationError() }
        catch {
            try validateAuthenticationFallback(after: error)
            Logger.info("signUp failed (likely already registered), trying signIn: \(error)", context: "PubkyProfileManager")
            return try await signIn()
        }
    }

    private nonisolated static func validateAuthenticationFallback(after error: Error) throws {
        if PubkyCredentialLocalError.isLocalFailure(error) || error is ProfileRemovalStore.StoreError {
            throw error
        }
        try ProfileOperationAdmission.shared.checkCurrent()
    }

    /// Signs in with a pubky owned by Pubky Ring. The secret is read just-in-time and never persisted here.
    func adoptRingIdentity(
        pubky: String,
        loadSecret: (String, String) -> String? = SharedPubkyKeychain.loadSecret,
        signIn: @escaping @Sendable (String) async throws -> Void = { try await PubkyProfileManager.signInWithRingKey($0) },
        fetchProfile: (@Sendable (String) async -> PubkyProfile?)? = nil,
        sdkService: PaykitSdkService = .shared
    ) async throws -> PubkyProfile? {
        guard !Self.isRingAdoptionInFlight else {
            throw PubkyServiceError.authFailed("Pubky Ring sign-in already in progress")
        }
        let admission = sdkService.profileAdmission
        return try await admission.withSessionTransition {
            try Self.beginSessionMutation()
            Self.isRingAdoptionInFlight = true
            defer {
                Self.isRingAdoptionInFlight = false
                isAdoptingRingIdentity = false
                Self.endSessionMutation()
            }
            let sourceApp = SharedPubkyKeychain.ringSourceApp
            guard let secretKeyHex = loadSecret(sourceApp, pubky) else {
                throw PubkyServiceError.authFailed("Pubky Ring key unavailable")
            }

            let previousAdoptedIdentity = AdoptedPubkyReference.current
            let attempt = try await sdkService.beginCredentialAttempt()
            var acknowledged = false
            isAdoptingRingIdentity = true
            AdoptedPubkyReference.current = (sourceApp, pubky)
            do {
                let adoptedPublicKey = try await admission.withDetached {
                    let publicKey = try Self.publicKeyFromSecretKey(secretKeyHex)
                    try await signIn(secretKeyHex)
                    return publicKey
                }
                let prepared = try await prepareRingAdoption(publicKey: adoptedPublicKey, fetchProfile: fetchProfile)
                try admission.checkCurrent()
                let activation = try await sdkService.commitCredentialAttempt(attempt)
                acknowledged = true
                #if DEBUG
                    await beforeCommittedIdentityInstallForTesting?()
                #endif
                try admission.validateAcknowledgedLocalCompletion()
                Self.applyCommittedActivation(activation)
                installRingAdoption(publicKey: adoptedPublicKey, prepared: prepared)
                return prepared.profile
            } catch {
                if !acknowledged, let currentAdoptedIdentity = AdoptedPubkyReference.current,
                   currentAdoptedIdentity.sourceApp == sourceApp,
                   currentAdoptedIdentity.pubky == pubky
                {
                    AdoptedPubkyReference.current = previousAdoptedIdentity
                }
                if !acknowledged {
                    do { try await Task.detached { try await sdkService.rollbackCredentialAttempt(attempt) }.value }
                    catch {
                        refreshRemovalRecovery()
                        initializationErrorMessage = error.localizedDescription
                        Logger.error("Adopted identity requires local recovery: \(error)", context: "PubkyProfileManager")
                    }
                }
                throw error
            }
        }
    }

    private struct PreparedRingAdoption {
        let profile: PubkyProfile?
        let reusesRowProfile: Bool
    }

    private func prepareRingAdoption(
        publicKey adoptedPublicKey: String,
        fetchProfile: (@Sendable (String) async -> PubkyProfile?)? = nil
    ) async throws -> PreparedRingAdoption {
        let adoptionRevision = Self.sessionRevision
        let previousPublicKey = publicKey
        // Read only after sign-in: when lookups are contended, the tapped row's result lands after the tap. Only a found
        // row profile for this key is reused; anything else takes the fetch that decides profile setup.
        let rowKey = PubkyPublicKeyFormat.normalized(adoptedPublicKey)
        var adoptedProfile = rowKey.flatMap { ringIdentityProfiles[$0] }
        if adoptedProfile == nil, let rowKey, let lookup = ringIdentityLookups[rowKey], !lookup.task.isCancelled {
            // The row's lookup is already ahead of a fresh fetch for the same key.
            await lookup.task.value
            adoptedProfile = ringIdentityProfiles[rowKey]
        }
        let reusesRowProfile = PubkyPublicKeyFormat.matches(adoptedProfile?.publicKey, adoptedPublicKey)
        if !reusesRowProfile {
            adoptedProfile = if let fetchProfile {
                await fetchProfile(adoptedPublicKey)
            } else {
                await fetchRemoteProfile(publicKey: adoptedPublicKey)
            }
        }
        try Task.checkCancellation()
        guard adoptionRevision == Self.sessionRevision, publicKey == previousPublicKey else {
            throw CancellationError()
        }
        return PreparedRingAdoption(profile: adoptedProfile, reusesRowProfile: reusesRowProfile)
    }

    private func installRingAdoption(publicKey adoptedPublicKey: String, prepared: PreparedRingAdoption) {
        invalidateProfileLoads()
        reloadCachedProfileMetadata()
        publicKey = adoptedPublicKey
        authState = .authenticated
        Self.notifyAppStateBackupChanged()
        let adoptionRevision = Self.sessionRevision
        clearRingIdentityProfiles()

        setProfileSetupPending(prepared.profile == nil)
        if let profile = prepared.profile {
            commitProfile(profile)
        }
        if prepared.reusesRowProfile {
            // A row profile can be from earlier in the session, so it is refreshed behind navigation.
            let generation = profileWriteGeneration
            scheduleProfileRead {
                await self.refreshReusedRingProfile(publicKey: adoptedPublicKey, generation: generation, adoptionRevision: adoptionRevision)
            }
        }
    }

    private func completeRingAdoption(publicKey: String) async throws -> PubkyProfile? {
        let prepared = try await prepareRingAdoption(publicKey: publicKey)
        installRingAdoption(publicKey: publicKey, prepared: prepared)
        return prepared.profile
    }

    /// Only a definitive not-found undoes the reused profile, leaving the key as adopting one without a profile does so
    /// routing prompts profile setup. Any other failure may just mean offline and keeps it. Dropped if the identity
    /// changed or a newer profile write landed.
    private func refreshReusedRingProfile(publicKey adoptedPublicKey: String, generation: Int, adoptionRevision: UUID) async {
        guard let removalGeneration = try? ProfileRemovalStore.shared.requireNoPending(), !Self.isProfileDeletionInFlight,
              let read = beginProfileRead(
                  .reusedRingProfileRefresh(adoptionRevision: adoptionRevision),
                  publicKey: adoptedPublicKey,
                  generation: generation
              ) else { return }
        defer { endProfileRead(read) }
        let resolve = remoteProfileResolver
        func isStillCurrent() -> Bool {
            !Task.isCancelled && !Self.isProfileDeletionInFlight &&
                (try? ProfileRemovalStore.shared.validate(generation: removalGeneration)) != nil &&
                adoptionRevision == Self.sessionRevision && publicKey == adoptedPublicKey && profileWriteGeneration == generation
        }

        do {
            let refreshedProfile = try await Task.detached {
                try await resolve(adoptedPublicKey)
            }.value
            guard isStillCurrent() else { return }
            profile = refreshedProfile
            cacheProfileMetadata(refreshedProfile)
        } catch PubkyServiceError.profileNotFound {
            guard isStillCurrent() else { return }
            Logger.info("Adopted Pubky Ring profile no longer exists, starting profile setup", context: "PubkyProfileManager")
            invalidateProfileLoads()
            profile = nil
            if PubkyPublicKeyFormat.matches(cachedProfileOwner, adoptedPublicKey) {
                clearCachedProfileMetadata()
            }
            setProfileSetupPending(true)
        } catch {
            Logger.warn("Failed to refresh the adopted Pubky Ring profile: \(error)", context: "PubkyProfileManager")
        }
    }

    private nonisolated static func signInWithRingKey(_ secretKeyHex: String) async throws {
        let publicKey = try publicKeyFromSecretKey(secretKeyHex)
        do {
            _ = try await PubkyService.signIn(secretKeyHex: secretKeyHex)
        } catch {
            try Self.validateAuthenticationFallback(after: error)
            Logger.warn("Sign-in with the Pubky Ring key failed: \(error)", context: "PubkyProfileManager")
            // Signup rewrites the homeserver record, so only a Ring key that was never published signs up.
            guard await Self.isUnpublishedIdentity(publicKey: publicKey) else { throw error }
            try ProfileOperationAdmission.shared.checkCurrent()
            _ = try await Self.signUpToHomeserver(secretKeyHex: secretKeyHex)
        }
    }

    static func completeIdentityCreation(
        loadStoredSecretKey: () async throws -> String?,
        signIn: (String) async throws -> String,
        signUp: () async throws -> String,
        createProfile: (String) async throws -> Void,
        discardSessionAccess: () async -> Void
    ) async throws {
        if let secretKeyHex = try await loadStoredSecretKey(), !secretKeyHex.isEmpty {
            let publicKey = try await signIn(secretKeyHex)
            try await createProfile(publicKey)
            return
        }

        let publicKey = try await signUp()
        do {
            try await createProfile(publicKey)
        } catch {
            await discardSessionAccess()
            throw error
        }
    }

    @discardableResult
    private func createProfile(
        publicKey: String,
        name: String,
        bio: String,
        links: [PubkyProfileLink],
        tags: [String],
        existingImageUrl: String?,
        avatarImage: UIImage?,
        installsProfile: Bool = true
    ) async throws -> PubkyProfile {
        var avatarUri: String?
        if let avatarImage {
            avatarUri = try await uploadAvatar(image: avatarImage)
        }
        let imageUrl = Self.resolvedImageUrl(newImageUrl: avatarUri, existingImageUrl: existingImageUrl)

        try await writeProfile(name: name, bio: bio, imageUrl: imageUrl, links: links, tags: tags)
        Self.notifyAppStateBackupChanged()

        let createdProfile = PubkyProfile(
            publicKey: publicKey,
            name: name,
            bio: bio,
            imageUrl: imageUrl,
            links: links,
            tags: tags,
            status: nil
        )
        if installsProfile {
            installCreatedProfile(createdProfile)
        }
        return createdProfile
    }

    private func installCreatedProfile(_ createdProfile: PubkyProfile) {
        publicKey = createdProfile.publicKey
        authState = .authenticated
        commitProfile(createdProfile)
        setProfileSetupPending(false)
    }

    func approveSignupAuth(request: PubkyAuthRequest) async throws {
        return try await ProfileOperationAdmission.shared.withSessionTransition {
            guard request.isSignup, request.bitkitClaim == nil, let homeserver = request.homeserverPublicKey else {
                throw PubkyServiceError.invalidAuthUrl
            }
            guard publicKey == nil, try !Self.hasStoredIdentity() else {
                throw PubkySignupError.alreadySignedIn
            }

            let revision = Self.sessionRevision
            let (publicKey, secretKeyHex) = try await deriveKeys()
            guard revision == Self.sessionRevision else { throw CancellationError() }
            guard self.publicKey == nil, try !Self.hasStoredIdentity() else {
                throw PubkySignupError.alreadySignedIn
            }

            try await completeSignupAuthentication(
                publicKey: publicKey,
                registerIdentity: {
                    try await PubkyService.registerIdentity(
                        secretKeyHex: secretKeyHex,
                        homeserverZ32: homeserver,
                        signupCode: request.signupToken
                    )
                },
                approveAuth: {
                    try await PubkyService.approveSignupAuthorization(request: request, secretKeyHex: secretKeyHex)
                },
                activateIdentity: { try await PubkyService.activateRegisteredIdentity($0) }
            )
            Self.publishOwnSharedRecord()
        }
    }

    private func completeSignupAuthentication(
        publicKey: String,
        registerIdentity: () async throws -> PubkyRegisteredIdentity,
        approveAuth: @escaping () async throws -> Void,
        activateIdentity: (PubkyRegisteredIdentity) async throws -> Void,
        authorizationTimeout: Duration = .seconds(30)
    ) async throws {
        return try await removalAdmission.withSessionTransition {
            guard !isSignupInFlight else { throw PubkySignupError.inProgress }
            try Self.beginSessionMutation()
            isSignupInFlight = true
            let revision = Self.sessionRevision
            defer {
                isSignupInFlight = false
                Self.endSessionMutation()
            }

            setProfileSetupPending(false)
            let registeredSession = try await registerIdentity()
            try removalAdmission.checkCurrent()
            guard revision == Self.sessionRevision else { throw CancellationError() }
            try await approveSignupWithTimeout(authorizationTimeout, operation: approveAuth)
            try removalAdmission.checkCurrent()
            guard revision == Self.sessionRevision else { throw CancellationError() }
            try await activateIdentity(registeredSession)
            try removalAdmission.validateCommittedOrCurrentLocalCompletion()
            guard revision == Self.sessionRevision else { throw CancellationError() }

            UserDefaults.standard.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
            reloadCachedProfileMetadata()
            self.publicKey = publicKey
            authState = .authenticated
            setProfileSetupPending(true)
            Self.notifyAppStateBackupChanged()
        }
    }

    private func approveSignupWithTimeout(_ timeout: Duration, operation: @escaping () async throws -> Void) async throws {
        // The FFI request may ignore cancellation. Only race approval, so a late response cannot activate an abandoned signup.
        let (stream, continuation) = AsyncStream<Result<Void, Error>>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let scope = try removalAdmission.capture()
        let operationTask = Task {
            defer { removalAdmission.release(scope) }
            do {
                try Task.checkCancellation()
                try await removalAdmission.withScope(scope) { try await operation() }
                continuation.yield(.success(()))
            } catch {
                if !(error is CancellationError) {
                    Logger.warn("Pubky signup relay approval failed", context: "PubkyProfileManager")
                }
                continuation.yield(.failure(error))
            }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                continuation.yield(.failure(URLError(.timedOut)))
            } catch {}
        }

        try await withTaskCancellationHandler {
            defer {
                operationTask.cancel()
                timeoutTask.cancel()
                continuation.finish()
            }
            for await result in stream {
                try Task.checkCancellation()
                return try result.get()
            }
            throw CancellationError()
        } onCancel: {
            operationTask.cancel()
            timeoutTask.cancel()
            continuation.finish()
        }
    }

    /// Saves an edit to the signed-in profile, uploading `avatarImage` first when there is one, and returns whether it was
    /// saved. The edit belongs to the session it was started in, bound before it uploads anything. Once that session ends
    /// or changes, or nothing is signed in, it stops quietly and returns false: it reports no error, the upload and the
    /// publication each write nothing once another identity is signed in, and the profile and setup state stay as they are.
    @discardableResult
    func saveProfile(
        name: String,
        bio: String,
        links: [PubkyProfileLink],
        tags: [String] = [],
        avatarImage: UIImage? = nil
    ) async throws -> Bool {
        return try await ProfileOperationAdmission.shared.withOperation {
            guard let session = currentSession else { return false }
            _ = try activeSessionSecret()
            return try await saveProfileEdit(name: name, bio: bio, links: links, tags: tags, avatarImage: avatarImage, session: session)
        }
    }

    /// Starting the edit drops every profile read that started before it, ahead of the avatar upload, so a refresh that finds
    /// the profile missing while the edit uploads or publishes can no longer clear the profile or start profile setup. The
    /// dropped read waits for every save in flight, as edits from Profile and Edit Profile can overlap: a published profile
    /// makes it moot, and once the last save in flight fails with an error while its session is still signed in, nothing
    /// was saved, so the read runs again rather than leaving the profile unchecked. It never runs while another save is in
    /// flight, which would publish over a profile that read cleared. A save dropped because its session ended or another
    /// identity is signed in runs nothing again, as that read belonged to a session the user has left.
    private func saveProfileEdit(
        name: String,
        bio: String,
        links: [PubkyProfileLink],
        tags: [String],
        avatarImage: UIImage?,
        session: SignedInSession
    ) async throws -> Bool {
        if profileReadAwaitingSaves?.session != session {
            profileReadAwaitingSaves = applicableProfileRead.map { (read: $0, session: session) }
        }
        invalidateProfileLoads()
        profileSavesInFlight += 1
        do {
            let isSaved = try await uploadAndPublishProfileEdit(
                name: name,
                bio: bio,
                links: links,
                tags: tags,
                avatarImage: avatarImage,
                session: session
            )
            profileSavesInFlight -= 1
            return isSaved
        } catch {
            profileSavesInFlight -= 1
            rerunProfileReadAwaitingSaves(afterFailedSaveIn: session)
            throw error
        }
    }

    private func uploadAndPublishProfileEdit(
        name: String,
        bio: String,
        links: [PubkyProfileLink],
        tags: [String],
        avatarImage: UIImage?,
        session: SignedInSession
    ) async throws -> Bool {
        var newImageUrl: String?
        if let avatarImage {
            do {
                newImageUrl = try await avatarUploader(compressAvatar(avatarImage), session.publicKey)
            } catch PubkyServiceError.identityChanged {
                Logger.info("Dropped a profile save whose avatar upload was for another identity", context: "PubkyProfileManager")
                return false
            } catch {
                guard currentSession == session else { return false }
                throw error
            }
            guard currentSession == session else {
                Logger.info("Dropped a profile save that a session change overtook during its avatar upload", context: "PubkyProfileManager")
                return false
            }
        }
        return try await publishProfileEdit(name: name, bio: bio, links: links, tags: tags, newImageUrl: newImageUrl, session: session)
    }

    /// A published profile ends any pending setup. The SDK publishes only while the session's identity is still signed in,
    /// and a save that a sign-out or another identity overtakes changes nothing here, as it belongs to a session the user
    /// has left. Returns whether the edit was saved.
    private func publishProfileEdit(
        name: String,
        bio: String,
        links: [PubkyProfileLink],
        tags: [String],
        newImageUrl: String?,
        session: SignedInSession
    ) async throws -> Bool {
        let resolvedImageUrl = Self.resolvedImageUrl(newImageUrl: newImageUrl, existingImageUrl: profile?.imageUrl)

        do {
            try await writeProfile(
                name: name,
                bio: bio,
                imageUrl: resolvedImageUrl,
                links: links,
                tags: tags,
                expectedIdentity: session.publicKey
            )
        } catch PubkyServiceError.identityChanged {
            Logger.info("Dropped a profile save for an identity that is no longer signed in", context: "PubkyProfileManager")
            return false
        } catch {
            guard currentSession == session else { return false }
            throw error
        }
        guard currentSession == session else {
            Logger.info("Dropped a profile save that a session change overtook", context: "PubkyProfileManager")
            return false
        }

        let updatedProfile = PubkyProfile(
            publicKey: session.publicKey,
            name: name,
            bio: bio,
            imageUrl: resolvedImageUrl,
            links: links,
            tags: tags,
            status: profile?.status
        )
        commitProfile(updatedProfile)
        setProfileSetupPending(false)
        return true
    }

    #if DEBUG
        /// Publication tests simulate an in-process pause independently of destructive cleanup.
        /// Actual removal tests enter through prepareRemoval/confirmRemoval and the persistent store.
        func withAutomaticWorkPausedForTesting(_ operation: () async throws -> Void) async throws {
            guard !Self.isProfileDeletionInFlight, Self.sessionMutationCount == 0, initializationTask == nil else {
                throw PubkyServiceError.identityChanged
            }
            Self.isProfileDeletionInFlight = true
            isDeletingProfile = true
            let pause = await PrivatePaykitService.shared.beginProfileDeletion()
            do {
                try await operation()
            } catch {
                await PrivatePaykitService.shared.endProfileDeletion(id: pause)
                Self.isProfileDeletionInFlight = false
                isDeletingProfile = false
                throw error
            }
            await PrivatePaykitService.shared.endProfileDeletion(id: pause)
            Self.isProfileDeletionInFlight = false
            isDeletingProfile = false
        }
    #endif

    func deleteProfile(cleanPrivatePaykitEndpoints: Bool = true, expectedSession: SignedInSession? = nil) async throws {
        guard let plan = removalPlan, plan.confirmation.action == .deleteProfile || plan.confirmation.action == .unlink else {
            throw RemovalError.confirmationRequired
        }
        if let expectedSession {
            guard expectedSession.revision == plan.sessionRevision, expectedSession.publicKey == plan.owner else {
                throw RemovalError.confirmationChanged
            }
        }
        _ = try await confirmRemoval(plan.confirmation)
    }

    func prepareRemoval(action: RemovalAction, contacts: ContactsManager? = nil,
                        expectedOwner: RemovalPresentationOwner? = nil) async throws -> RemovalConfirmation
    {
        if action == .disconnectLocally, expectedOwner == nil {
            throw RemovalError.confirmationRequired
        }
        if let expectedOwner, !ownsRemovalPresentation(expectedOwner) {
            throw RemovalError.confirmationChanged
        }
        let admission = removalAdmission
        let generation = try admission.snapshot()
        guard Self.sessionMutationCount == 0, !Self.isProfileDeletionInFlight, initializationTask == nil else {
            throw PubkyServiceError.identityChanged
        }
        let owner = publicKey
        let revision = Self.sessionRevision
        let profileGeneration = profileWriteGeneration
        let removesContacts = action == .deleteProfile || action == .unlink
        if removesContacts {
            guard currentSession != nil, contacts != nil else { throw PubkyServiceError.sessionNotActive }
        }
        let confirmation = RemovalConfirmation(id: UUID(), action: action)
        removalPreparation = confirmation.id
        removalPlan?.revocation?.revoke()
        removalPlan = nil
        var captured: ProfileSessionRevocation?
        do {
            return try await admission.withOperation {
                let profile = action == .deleteProfile && owner != nil
                    ? try await removalServices.readProfile(owner!) : nil
                let snapshot = removesContacts ? try await contacts?.prepareRemovalSnapshot() : nil
                if snapshot != nil, let owner {
                    try await removalServices.validateSubscriptions(owner)
                }
                let withdrawEndpoints = action != .disconnectLocally && owner != nil && authState == .authenticated
                if withdrawEndpoints, let owner {
                    captured = try await removalServices.captureRevocation(owner)
                }
                try admission.validate(generation)
                guard removalPreparation == confirmation.id, Self.sessionRevision == revision,
                      publicKey == owner, profileWriteGeneration == profileGeneration else { throw RemovalError.confirmationChanged }
                removalPlan = RemovalPlan(confirmation: confirmation, sessionRevision: revision, owner: owner,
                                          profileGeneration: profileGeneration, admissionGeneration: generation,
                                          profile: profile,
                                          withdrawEndpoints: withdrawEndpoints,
                                          contacts: removesContacts ? contacts : nil, contactSnapshot: snapshot, revocation: captured)
                return confirmation
            }
        } catch {
            captured?.revoke()
            if removalPreparation == confirmation.id {
                removalPreparation = nil
            }
            if removalPlan?.confirmation.id == confirmation.id {
                removalPlan = nil
            }
            throw error
        }
    }

    func cancelRemovalConfirmation(_ confirmation: RemovalConfirmation?) {
        guard let confirmation else { return }
        if removalPreparation == confirmation.id {
            removalPreparation = nil
        }
        if removalPlan?.confirmation.id == confirmation.id {
            removalPlan?.revocation?.revoke()
            removalPlan = nil
        }
    }

    func confirmRemoval(_ confirmation: RemovalConfirmation) async throws -> RemovalCompletion {
        try Task.checkCancellation()
        guard let plan = removalPlan, plan.confirmation == confirmation else { throw RemovalError.confirmationRequired }
        try validateRemovalOwner(plan)
        if let snapshot = plan.contactSnapshot {
            try plan.contacts?.requireCurrentRemovalSnapshot(snapshot)
        }
        let admission = removalAdmission
        try admission.validate(plan.admissionGeneration)
        if let snapshot = plan.contactSnapshot, let owner = plan.owner {
            try await admission.withOperation {
                try await plan.contacts?.validateRemovalSnapshot(snapshot)
                try await removalServices.validateSubscriptions(owner)
            }
        }
        // The dialog or its owner may have changed while eligibility was being checked.
        // Reserve only after leaving the ordinary scope, without suspending after these checks.
        guard removalPlan?.confirmation == confirmation, removalPreparation == confirmation.id else {
            throw RemovalError.confirmationChanged
        }
        try validateRemovalOwner(plan)
        if let snapshot = plan.contactSnapshot {
            try plan.contacts?.requireCurrentRemovalSnapshot(snapshot)
        }
        try admission.validate(plan.admissionGeneration)
        removalPlan = nil
        removalPreparation = nil
        let kind: ProfileOperationAdmission.Kind = plan.withdrawEndpoints ? .removal : .localRecovery
        let scope = try admission.reserve(kind: kind, id: confirmation.id, expected: plan.admissionGeneration)
        return try await runRemoval(scope: scope, id: confirmation.id, plan: plan)
    }

    private func validateRemovalOwner(_ plan: RemovalPlan) throws {
        try Task.checkCancellation()
        guard Self.sessionRevision == plan.sessionRevision, Self.sessionMutationCount == 0,
              publicKey == plan.owner, profileWriteGeneration == plan.profileGeneration
        else {
            throw RemovalError.confirmationChanged
        }
    }

    private func validateRemoteRemovalOwner(_ plan: RemovalPlan) async throws {
        try validateRemovalOwner(plan)
        guard let revocation = plan.revocation else { throw RemovalError.confirmationChanged }
        try await revocation.validate()
        try validateRemovalOwner(plan)
    }

    func finishPendingRemoval(id: UUID) async throws -> RemovalCompletion {
        guard !isDeletingProfile else { throw RemovalError.confirmationChanged }
        let pending = try removalStore.pending()
        guard pending?.id == id, pending?.scope == .profile else { throw RemovalError.confirmationChanged }
        liveRemoval?.lease.retire()
        liveRemoval = nil
        remoteRemovalConfirmation = nil
        let scope = try removalAdmission.reserve(kind: .localRecovery, id: id)
        return try await runRemoval(scope: scope, id: id, plan: nil)
    }

    func canRetryRemoteRemoval(id: UUID) -> Bool {
        guard !Self.isProfileDeletionInFlight, !isDeletingProfile, let live = liveRemoval,
              live.plan.confirmation.id == id, live.logoutStarted, !live.logoutAcknowledged,
              live.privateAcknowledged, live.publicAcknowledged, live.lease.canResume,
              (try? validateRemovalOwner(live.plan)) != nil,
              let pending = try? removalStore.pending(), pending.id == id, pending.scope == .profile else { return false }
        return true
    }

    func prepareRemoteRemovalRetry(id: UUID) async throws -> RemoteRemovalConfirmation {
        guard canRetryRemoteRemoval(id: id), let live = liveRemoval, let revocation = live.plan.revocation else {
            throw RemovalError.confirmationChanged
        }
        remoteRemovalConfirmation = nil
        // This checks only the original local binding. Protocol negotiation waits for the new confirmation.
        do {
            try await live.lease.withOperation { try await revocation.validate() }
        } catch {
            if !(error is CancellationError) {
                live.lease.retire()
            }
            throw error
        }
        guard canRetryRemoteRemoval(id: id), liveRemoval === live else { throw RemovalError.confirmationChanged }
        let confirmation = RemoteRemovalConfirmation(id: UUID(), removalID: id)
        remoteRemovalConfirmation = confirmation
        return confirmation
    }

    func cancelRemoteRemovalRetry(_ confirmation: RemoteRemovalConfirmation?) {
        if remoteRemovalConfirmation == confirmation {
            remoteRemovalConfirmation = nil
        }
    }

    func confirmRemoteRemovalRetry(_ confirmation: RemoteRemovalConfirmation) async throws -> RemovalCompletion {
        guard remoteRemovalConfirmation == confirmation, canRetryRemoteRemoval(id: confirmation.removalID),
              let live = liveRemoval, let revocation = live.plan.revocation else { throw RemovalError.confirmationRequired }
        remoteRemovalConfirmation = nil
        Self.isProfileDeletionInFlight = true
        isDeletingProfile = true
        defer {
            Self.isProfileDeletionInFlight = false
            isDeletingProfile = false
            refreshRemovalRecovery()
        }
        let id = confirmation.removalID
        let scope = live.lease.scope
        var completion: RemovalCompletion?
        do {
            try await withRemovalWork(lease: live.lease, id: id, live: live) {
                try await validateRemoteRemovalOwner(live.plan)
                // Endpoint, contact and profile cleanup already completed under this same live intent.
                try await revocation.execute()
                live.logoutAcknowledged = await revocation.acknowledged()
                guard live.logoutAcknowledged else { throw RemovalError.confirmationChanged }
                try validateRemovalOwner(live.plan)
                completion = try await completeRemoval(scope: scope, plan: live.plan, remoteDeleted: live.remoteProfileDeleted)
            }
        } catch {
            if live.logoutAcknowledged || Task.isCancelled || !live.lease.canResume || (try? validateRemovalOwner(live.plan)) == nil {
                live.lease.retire()
            }
            if let completion {
                return completion
            }
            throw error
        }
        live.lease.retire()
        liveRemoval = nil
        guard let completion else { throw ProfileRemovalStore.StoreError.changed }
        return completion
    }

    private func withRemovalWork(lease: ProfileRemovalLease, id: UUID, live: LiveRemoval?,
                                 operation: () async throws -> Void) async throws
    {
        try await lease.withOperation {
            await removalServices.pause(id)
            do {
                try await operation()
            } catch {
                await removalServices.resume(id)
                if let live, let revocation = live.plan.revocation {
                    // The native attempt and SDK-lock tail have returned, but our local tail still owns the drain holder.
                    live.logoutAcknowledged = await revocation.acknowledged()
                    if live.logoutStarted {
                        liveRemoval = live
                    }
                }
                throw error
            }
            await removalServices.resume(id)
        }
    }

    private func completeRemoval(scope: ProfileOperationAdmission.Scope, plan: RemovalPlan?,
                                 remoteDeleted: Bool) async throws -> RemovalCompletion
    {
        try removalAdmission.requireLocalOnly(scope)
        if let revocation = plan?.revocation {
            try await removalServices.completeRevokedLocal(revocation)
        } else {
            try await removalServices.completeLocal()
        }
        clearAuthenticatedStateAfterLocalCleanup()
        plan?.contacts?.finishProfileRemoval()
        let endedRevision = Self.sessionRevision
        let completedGeneration = try removalAdmission.complete(scope)
        failedRemovalID = nil
        return RemovalCompletion(remoteProfileDeleted: remoteDeleted, endedRevision: endedRevision,
                                 admissionGeneration: completedGeneration)
    }

    private func runRemoval(scope: ProfileOperationAdmission.Scope, id: UUID, plan: RemovalPlan?,
                            validateLocalIntent: (() throws -> Void)? = nil) async throws -> RemovalCompletion
    {
        let admission = removalAdmission
        let lease = ProfileRemovalLease(scope: scope, revokeRemoteAdmission: { plan?.revocation?.revoke() })
        let live = plan.map { LiveRemoval(plan: $0, lease: lease) }
        var retainIntent = false
        defer {
            if !retainIntent {
                lease.retire()
            }
        }
        Self.isProfileDeletionInFlight = true
        isDeletingProfile = true
        defer {
            Self.isProfileDeletionInFlight = false
            isDeletingProfile = false
            refreshRemovalRecovery()
        }
        var completion: RemovalCompletion?
        do {
            try await withRemovalWork(lease: lease, id: id, live: live) {
                try await admission.drain(before: scope)
                if let plan {
                    try validateRemovalOwner(plan)
                }
                try validateLocalIntent?()
                try admission.persist(scope)
                failedRemovalID = id
                refreshRemovalRecovery()
                var remoteDeleted = false
                if let plan, plan.withdrawEndpoints {
                    try await validateRemoteRemovalOwner(plan)
                    if let snapshot = plan.contactSnapshot {
                        try await plan.contacts?.validateRemovalSnapshot(snapshot)
                        if let owner = plan.owner {
                            try await removalServices.validateSubscriptions(owner)
                        }
                    }
                    try await validateRemoteRemovalOwner(plan)
                    try await removalServices.withdrawPrivate()
                    live?.privateAcknowledged = true
                    try await validateRemoteRemovalOwner(plan)
                    try await removalServices.withdrawPublic()
                    live?.publicAcknowledged = true
                    try await validateRemoteRemovalOwner(plan)
                    if let snapshot = plan.contactSnapshot {
                        try await plan.contacts?.removeConfirmedContacts(snapshot)
                    }
                    try await validateRemoteRemovalOwner(plan)
                    if plan.confirmation.action == .deleteProfile, let record = plan.profile, let owner = plan.owner {
                        try await removalAdmission
                            .withDetached { [removalServices] in try await removalServices.deleteProfile(owner, record.revision) }
                        remoteDeleted = true
                        live?.remoteProfileDeleted = true
                    }
                    try await validateRemoteRemovalOwner(plan)
                    guard let revocation = plan.revocation else { throw RemovalError.confirmationChanged }
                    live?.logoutStarted = true
                    try await revocation.execute()
                    live?.logoutAcknowledged = await revocation.acknowledged()
                    guard live?.logoutAcknowledged == true else { throw RemovalError.confirmationChanged }
                    try validateRemovalOwner(plan)
                }
                try validateLocalIntent?()
                completion = try await completeRemoval(scope: scope, plan: plan, remoteDeleted: remoteDeleted)
            }
        } catch {
            if let live, live.logoutStarted {
                retainIntent = !live.logoutAcknowledged && !Task.isCancelled && lease.canResume &&
                    (try? validateRemovalOwner(live.plan)) != nil
            }
            if let completion {
                return completion
            }
            throw error
        }
        guard let completion else { throw ProfileRemovalStore.StoreError.changed }
        return completion
    }

    func ownsRemovalCompletion(_ completion: RemovalCompletion) -> Bool {
        Self.sessionRevision == completion.endedRevision && publicKey == nil &&
            (try? removalAdmission.validate(completion.admissionGeneration)) != nil
    }

    var pendingProfileRemovalID: UUID? {
        guard case let .pending(record) = removalRecovery, record.scope == .profile else { return nil }
        return record.id
    }

    private func writeProfile(
        name: String,
        bio: String,
        imageUrl: String?,
        links: [PubkyProfileLink],
        tags: [String] = [],
        expectedIdentity: String? = nil
    ) async throws {
        let profileData = PubkyProfileData(
            name: name,
            bio: bio,
            image: imageUrl,
            links: links.map { PubkyProfileData.Link(label: $0.label, url: $0.url) },
            tags: tags
        )

        let publish = profilePublisher
        try await ProfileOperationAdmission.shared.withDetached {
            try await publish(profileData, expectedIdentity)
        }
    }

    private func discardAbandonedSession(
        revokeSessionAccess: @escaping () async throws -> Void,
        forgetSessionAccess: @escaping () async throws -> Void
    ) async {
        do {
            try await revokeSessionAccess()
        } catch {
            Logger.warn("Failed to revoke abandoned Pubky session: \(error)", context: "PubkyProfileManager")
            do {
                try await forgetSessionAccess()
            } catch {
                Logger.warn("Failed to forget abandoned Pubky session access: \(error)", context: "PubkyProfileManager")
            }
        }
    }

    #if DEBUG
        func completeSignupAuthenticationForTesting(
            publicKey: String,
            registerIdentity: () async throws -> PubkyRegisteredIdentity,
            approveAuth: @escaping () async throws -> Void,
            activateIdentity: (PubkyRegisteredIdentity) async throws -> Void,
            authorizationTimeout: Duration = .seconds(30)
        ) async throws {
            try await removalAdmission.withSessionTransition {
                try await completeSignupAuthentication(
                    publicKey: publicKey,
                    registerIdentity: registerIdentity,
                    approveAuth: approveAuth,
                    activateIdentity: activateIdentity,
                    authorizationTimeout: authorizationTimeout
                )
            }
        }

        func discardAbandonedSessionForTesting(
            revokeSessionAccess: @escaping () async throws -> Void,
            forgetSessionAccess: @escaping () async throws -> Void
        ) async {
            await discardAbandonedSession(
                revokeSessionAccess: revokeSessionAccess,
                forgetSessionAccess: forgetSessionAccess
            )
        }

        func completeRingAdoptionForTesting(publicKey: String) async throws -> PubkyProfile? {
            try await completeRingAdoption(publicKey: publicKey)
        }

        /// `saveProfile` without its check for a stored session secret.
        @discardableResult
        func saveProfileForTesting(
            name: String,
            bio: String,
            links: [PubkyProfileLink],
            tags: [String],
            avatarImage: UIImage? = nil
        ) async throws -> Bool {
            guard let session = currentSession else { return false }
            return try await saveProfileEdit(name: name, bio: bio, links: links, tags: tags, avatarImage: avatarImage, session: session)
        }

        func clearAuthenticatedStateForTesting() {
            clearAuthenticatedState()
        }
    #endif

    // MARK: - Profile

    func loadProfile() async {
        if !isInitialized, let initializationTask {
            await initializationTask.value
            guard !Task.isCancelled else { return }
        }
        guard let removalGeneration = try? ProfileRemovalStore.shared.requireNoPending(), !Self.isProfileDeletionInFlight else { return }
        guard publicKey != nil else {
            await loadReadOnlyProfile()
            return
        }
        guard let pk = publicKey, let read = beginProfileRead(.load, publicKey: pk, generation: profileWriteGeneration) else { return }
        defer { endProfileRead(read) }
        let resolve = remoteProfileResolver

        do {
            let loadedProfile = try await Task.detached {
                try await resolve(pk)
            }.value
            if !Task.isCancelled, !Self.isProfileDeletionInFlight,
               (try? ProfileRemovalStore.shared.validate(generation: removalGeneration)) != nil,
               publicKey == pk, profileWriteGeneration == read.generation
            {
                profile = loadedProfile
                readOnlyProfile = nil
                cacheProfileMetadata(loadedProfile)
            }
        } catch {
            Logger.error("Failed to load profile: \(error)", context: "PubkyProfileManager")
        }
    }

    private func loadReadOnlyProfile() async {
        guard sessionRestorationDeferred, Self.sessionMutationCount == 0,
              let removalGeneration = try? ProfileRemovalStore.shared.requireNoPending(), !Self.isProfileDeletionInFlight else { return }
        let revision = Self.sessionRevision
        let pk = await Task.detached {
            Self.activeSecretKeyHex().flatMap { try? Self.publicKeyFromSecretKey($0) }
        }.value
        guard !Task.isCancelled, !Self.isProfileDeletionInFlight,
              (try? ProfileRemovalStore.shared.validate(generation: removalGeneration)) != nil,
              revision == Self.sessionRevision, Self.sessionMutationCount == 0,
              sessionRestorationDeferred, publicKey == nil
        else { return }
        guard let pk else {
            readOnlyProfile = nil
            return
        }
        if readOnlyProfile?.publicKey != pk || readOnlyProfile?.revision != revision {
            readOnlyProfile = (pk, nil, revision)
        }
        guard readOnlyProfile?.profile == nil,
              let read = beginProfileRead(.load, publicKey: pk, generation: profileWriteGeneration)
        else { return }
        defer { endProfileRead(read) }
        let resolve = remoteProfileResolver
        do {
            let loaded = try await Task.detached { try await resolve(pk) }.value
            guard !Task.isCancelled, !Self.isProfileDeletionInFlight,
                  (try? ProfileRemovalStore.shared.validate(generation: removalGeneration)) != nil,
                  revision == Self.sessionRevision, Self.sessionMutationCount == 0,
                  sessionRestorationDeferred, publicKey == nil, profileWriteGeneration == read.generation
            else { return }
            readOnlyProfile = (pk, loaded, revision)
        } catch {
            Logger.warn("Failed to load read-only Pubky profile: \(error)", context: "PubkyProfileManager")
        }
    }

    /// Fetch a remote profile by public key. Returns nil if no profile exists.
    func fetchRemoteProfile(publicKey: String) async -> PubkyProfile? {
        do {
            return try await remoteProfileResolver(publicKey)
        } catch {
            Logger.debug("No remote profile found for \(PubkyPublicKeyFormat.redacted(publicKey)): \(error)", context: "PubkyProfileManager")
            return nil
        }
    }

    nonisolated static func resolveRemoteProfile(publicKey: String) async throws -> PubkyProfile {
        let normalizedKey = PubkyPublicKeyFormat.normalized(publicKey) ?? publicKey
        if let resolution = try await PubkyService.resolveContactProfile(publicKey: normalizedKey, allowPubkyProfileFallback: true) {
            return PubkyProfile(resolution: resolution)
        }

        throw PubkyServiceError.profileNotFound
    }

    /// Sets a profile this device just wrote or chose, dropping any remote read that started before it, including one
    /// that waits for saves in flight.
    private func commitProfile(_ newProfile: PubkyProfile) {
        invalidateProfileLoads()
        profileReadAwaitingSaves = nil
        profile = newProfile
        cacheProfileMetadata(newProfile)
    }

    private func invalidateProfileLoads() {
        profileWriteGeneration += 1
    }

    /// The running read whose result can still apply, which the next write drops.
    private var applicableProfileRead: ProfileRead? {
        profileReadInFlight.flatMap { $0.generation == profileWriteGeneration ? $0 : nil }
    }

    /// Nil, starting nothing, while a read whose result can still apply runs, or once a write since `generation` has
    /// already dropped this one.
    private func beginProfileRead(_ kind: ProfileRead.Kind, publicKey: String, generation: Int) -> ProfileRead? {
        guard generation == profileWriteGeneration, applicableProfileRead == nil else { return nil }
        let read = ProfileRead(kind: kind, publicKey: publicKey, generation: generation)
        profileReadInFlight = read
        isLoadingProfile = true
        return read
    }

    private func endProfileRead(_ read: ProfileRead) {
        guard profileReadInFlight?.id == read.id else { return }
        profileReadInFlight = nil
        isLoadingProfile = false
    }

    /// Runs the read that saves dropped again once no save is in flight, as long as the failed save's session is still signed
    /// in. A save that starts before it runs takes the read over instead.
    private func rerunProfileReadAwaitingSaves(afterFailedSaveIn session: SignedInSession) {
        scheduleProfileRead { [self] in
            guard profileSavesInFlight == 0,
                  currentSession == session,
                  let awaiting = profileReadAwaitingSaves,
                  awaiting.session == session
            else { return }
            profileReadAwaitingSaves = nil
            switch awaiting.read.kind {
            case .load:
                await loadProfile()
            case let .reusedRingProfileRefresh(adoptionRevision):
                await refreshReusedRingProfile(
                    publicKey: awaiting.read.publicKey,
                    generation: profileWriteGeneration,
                    adoptionRevision: adoptionRevision
                )
            }
        }
    }

    private func scheduleProfileRead(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        let revision = Self.sessionRevision
        guard let removalGeneration = try? ProfileRemovalStore.shared.requireNoPending() else { return }
        Task { @MainActor in
            guard revision == Self.sessionRevision,
                  (try? ProfileRemovalStore.shared.validate(generation: removalGeneration)) != nil else { return }
            await ProfileOperationAdmission.$current.withValue(nil) { await operation() }
        }
    }

    // MARK: - Pubky Ring Choice Rows

    /// Looks up the rows that have no cached result, joining the live lookup of a row that has one. Cancelling the caller
    /// cancels each of its lookups that no other caller still waits on, so a screen the user has left stops queueing for
    /// read slots without stopping rows another choice screen still shows.
    func loadRingIdentityProfiles(_ pubkys: [String]) async {
        let lookups = Set(pubkys.compactMap(PubkyPublicKeyFormat.normalized)).compactMap { joinRingIdentityLookup($0) }

        await withTaskCancellationHandler {
            for lookup in lookups {
                await lookup.task.value
            }
        } onCancel: {
            for lookup in lookups where lookup.loaders.leave() {
                lookup.task.cancel()
            }
            // This handler runs off the main actor, so the stopped rows leave the published set on it.
            Task { @MainActor [weak self] in self?.publishRingIdentityLookupsInFlight() }
        }
    }

    /// Forgets the misses on returning to the app, since the user may have just published that pubky in Pubky Ring.
    func forgetRingIdentityMisses() {
        ringIdentityMisses.removeAll()
    }

    /// Stops every row lookup but `pubky`'s, whose result adoption can still reuse if it lands before sign-in finishes.
    /// A stopped lookup records no miss, so the next load looks that row up again.
    func cancelRingIdentityLookups(except pubky: String) {
        let keptKey = PubkyPublicKeyFormat.normalized(pubky)
        for (key, lookup) in ringIdentityLookups where key != keptKey {
            lookup.task.cancel()
        }
        publishRingIdentityLookupsInFlight()
    }

    private func joinRingIdentityLookup(_ key: String) -> RingIdentityLookup? {
        guard ringIdentityProfiles[key] == nil, !ringIdentityMisses.contains(key) else { return nil }
        // A cancelled lookup records no miss when it fails, so it cannot stand in for a live one, and one every caller
        // has left is being cancelled.
        if let lookup = ringIdentityLookups[key], !lookup.task.isCancelled, lookup.loaders.join() {
            return lookup
        }
        return startRingIdentityLookup(key)
    }

    private func startRingIdentityLookup(_ key: String) -> RingIdentityLookup {
        let id = UUID()
        let resolve = remoteProfileResolver
        let task = Task {
            var foundProfile: PubkyProfile?
            do {
                foundProfile = try await resolve(key)
            } catch {
                Logger.debug("No profile found for Pubky Ring key \(PubkyPublicKeyFormat.redacted(key)): \(error)", context: "PubkyProfileManager")
            }
            finishRingIdentityLookup(key, id: id, foundProfile: foundProfile)
        }
        let lookup = (id: id, task: task, loaders: RingIdentityLookupLoaders())
        ringIdentityLookups[key] = lookup
        publishRingIdentityLookupsInFlight()
        return lookup
    }

    /// Runs on the lookup's own task, so `Task.isCancelled` is that lookup's cancellation.
    private func finishRingIdentityLookup(_ key: String, id: UUID, foundProfile: PubkyProfile?) {
        // A newer lookup or a cache clear has replaced this one, so its result may be stale.
        guard ringIdentityLookups[key]?.id == id else { return }
        ringIdentityLookups[key] = nil

        if let foundProfile {
            ringIdentityProfiles[key] = foundProfile
        } else if !Task.isCancelled {
            ringIdentityMisses.insert(key)
        }
        publishRingIdentityLookupsInFlight()
    }

    private func clearRingIdentityProfiles() {
        ringIdentityLookups.values.forEach { $0.task.cancel() }
        ringIdentityLookups.removeAll()
        ringIdentityMisses.removeAll()
        ringIdentityProfiles.removeAll()
        publishRingIdentityLookupsInFlight()
    }

    private func publishRingIdentityLookupsInFlight() {
        ringIdentityLookupsInFlight = Set(ringIdentityLookups.filter { !$0.value.task.isCancelled }.keys)
    }

    // MARK: - Sign Out

    static func clearLocalState(
        forgetSessionAccess: @Sendable () async throws -> Void = { try await PubkyService.forgetSessionAccess() },
        removeSharedCredentials: () throws -> Void = { try SharedPubkyKeychain.removeAllOwnOrThrow() },
        flushPreferences: () -> Bool = { UserDefaults.standard.synchronize() }
    ) async throws {
        return try await ProfileOperationAdmission.shared.withOperation(access: .local) {
            // A wallet reset may revoke deletion's owner, but no replacement identity can start until deletion drains.
            try beginSessionMutation(allowDuringProfileDeletion: true)
            defer { endSessionMutation() }
            try await forgetSessionAccess()
            try await clearLocalAppState(removeSharedCredentials: removeSharedCredentials, flushPreferences: flushPreferences)
        }
    }

    private static func clearLocalAppState(
        removeSharedCredentials: () throws -> Void = { try SharedPubkyKeychain.removeAllOwnOrThrow() },
        flushPreferences: () -> Bool = { UserDefaults.standard.synchronize() }
    ) async throws {
        try removeSharedCredentials()
        AdoptedPubkyReference.current = nil
        let reservations = try await PrivatePaykitAddressReservationStore.shared.clearContactAssignmentsForRemoval()
        let privateState = try await PrivatePaykitService.shared.closeAndClear()
        await PubkyImageCache.shared.clear()
        clearCachedIdentityMetadata()
        UserDefaults.standard.removeObject(forKey: profileSetupPendingKey)
        clearPublicPaykitSharingState()
        #if DEBUG
            try ProfileRemovalTestFault.check("preferences:flush")
        #endif
        guard flushPreferences(), let domain = Bundle.main.bundleIdentifier,
              let stored = UserDefaults.standard.persistentDomain(forName: domain)
        else { throw ProfileRemovalStore.StoreError.unavailable }
        let removedKeys = [
            cachedIdentityKey, cachedNameKey, cachedImageUriKey, cachedProfileOwnerKey, profileSetupPendingKey,
            PublicPaykitService.reconciliationRevisionKey,
            AdoptedPubkyReference.sourceAppKey, AdoptedPubkyReference.pubkyKey, ContactsManager.contactProfileOverridesKey,
            PrivatePaykitService.deletedContactCleanupKeysKey, "publicPaykitBolt11", "publicPaykitBolt11PaymentHash", "publicPaykitBolt11ExpiresAt",
        ]
        let disabledKeys = [
            PublicPaykitService.publishingEnabledKey, PrivatePaykitService.publishingEnabledKey,
            ContactPaymentsService.confirmedPreferenceKey, PrivatePaykitService.cleanupPendingKey, PublicPaykitService.cleanupPendingKey,
        ]
        guard removedKeys.allSatisfy({ stored[$0] == nil }), disabledKeys.allSatisfy({ stored[$0] as? Bool == false }),
              stored[PrivatePaykitService.cacheStateKey] as? Data == privateState,
              stored[PrivatePaykitAddressReservationStore.defaultsKey] as? Data == reservations
        else { throw ProfileRemovalStore.StoreError.changed }
        try await PrivatePaykitService.shared.validateRemovalState(privateState)
        try await PrivatePaykitAddressReservationStore.shared.validateRemovalState(reservations)
        notifyAppStateBackupChanged()
    }

    private static func clearPublicPaykitSharingState() {
        PublicPaykitService.clearRemovedProfileReconciliation()
        UserDefaults.standard.set(false, forKey: PublicPaykitService.publishingEnabledKey)
        UserDefaults.standard.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
        UserDefaults.standard.set(false, forKey: ContactPaymentsService.confirmedPreferenceKey)
        PrivatePaykitService.setContactSharingCleanupPending(false)
        UserDefaults.standard.removeObject(forKey: "publicPaykitBolt11")
        UserDefaults.standard.removeObject(forKey: "publicPaykitBolt11PaymentHash")
        UserDefaults.standard.removeObject(forKey: "publicPaykitBolt11ExpiresAt")
    }

    static func removePublicPaykitEndpoints(context: String) async throws {
        var firstError: Error?
        do {
            try await PublicPaykitService.removePublishedEndpoints()
        } catch PubkyServiceError.sessionNotActive {
            Logger.debug("Skipping public Paykit endpoint cleanup because no session is active", context: context)
        } catch {
            firstError = error
        }

        do {
            try await PublicPaykitService.syncPaykitApp(privateSharingEnabled: false)
        } catch PubkyServiceError.sessionNotActive {
            Logger.debug("Skipping Paykit app capability update because no session is active", context: context)
        } catch {
            firstError = firstError ?? error
        }

        if let firstError {
            Logger.warn("Failed to remove public Paykit state before clearing session: \(firstError)", context: context)
            throw firstError
        }
    }

    static func removePublicPaykitEndpointsBestEffort(context: String) async {
        do {
            try await removePublicPaykitEndpoints(context: context)
            PublicPaykitService.setCleanupPending(false)
        } catch {
            PublicPaykitService.setCleanupPending(true)
        }
    }

    static func removePrivatePaykitEndpoints(
        context: String, deferAppSync: Bool = false, isSessionCurrent: (@MainActor () -> Bool)? = nil
    ) async throws {
        try await removePrivatePaykitEndpoints(context: context, isSessionCurrent: isSessionCurrent) {
            try await PrivatePaykitService.shared.removePublishedEndpoints(isSessionCurrent: isSessionCurrent, deferAppSync: deferAppSync)
        }
    }

    static func removePrivatePaykitEndpoints(
        context: String, isSessionCurrent: (@MainActor () -> Bool)?, operation: () async throws -> Void
    ) async throws {
        guard isSessionCurrent?() != false else { throw PubkyServiceError.identityChanged }
        do {
            try Task.checkCancellation()
            try await operation()
            guard isSessionCurrent?() != false else { throw PubkyServiceError.identityChanged }
            try Task.checkCancellation()
            PrivatePaykitService.setContactSharingCleanupPending(false)
        } catch {
            if isSessionCurrent?() != false {
                PrivatePaykitService.setContactSharingCleanupPending(true)
            }
            Logger.warn("Failed to remove private Paykit endpoints before clearing session: \(error)", context: context)
            throw error
        }
    }

    static func removePrivatePaykitEndpointsBestEffort(
        context: String, deferAppSync: Bool = false, isSessionCurrent: (@MainActor () -> Bool)? = nil
    ) async {
        try? await removePrivatePaykitEndpoints(context: context, deferAppSync: deferAppSync, isSessionCurrent: isSessionCurrent)
    }

    func signOut() async throws {
        let confirmation = try await prepareRemoval(action: .disconnect)
        _ = try await confirmRemoval(confirmation)
    }

    #if DEBUG
        func signOut(performSessionCleanup: @escaping @Sendable () async throws -> Void) async throws {
            try await signOut(allowDuringProfileDeletion: false, performSessionCleanup: performSessionCleanup)
        }

        private func signOut(
            allowDuringProfileDeletion: Bool, performSessionCleanup: @escaping @Sendable () async throws -> Void
        ) async throws {
            return try await ProfileOperationAdmission.shared.withOperation {
                let retainedProfile = hasReadOnlyProfileIdentity ? readOnlyProfile : nil
                try Self.beginSessionMutation(allowDuringProfileDeletion: allowDuringProfileDeletion)
                if let retainedProfile {
                    readOnlySignOutRevision = Self.sessionRevision
                    readOnlyProfile = (retainedProfile.publicKey, retainedProfile.profile, Self.sessionRevision)
                }
                defer {
                    readOnlySignOutRevision = nil
                    Self.endSessionMutation()
                }
                let publicSharingEnabled = UserDefaults.standard.bool(forKey: PublicPaykitService.publishingEnabledKey)
                let privateSharingEnabled = UserDefaults.standard.bool(forKey: PrivatePaykitService.publishingEnabledKey)

                do {
                    try await ProfileOperationAdmission.shared.withDetached {
                        try await performSessionCleanup()
                        try await Self.clearLocalAppState()
                    }
                } catch {
                    Self.markPaykitReconciliationPendingAfterFailedSignOut(
                        publicSharingEnabled: publicSharingEnabled,
                        privateSharingEnabled: privateSharingEnabled
                    )
                    throw error
                }

                clearAuthenticatedStateAfterLocalCleanup()
            }
        }

    #endif

    private func clearAuthenticatedStateAfterLocalCleanup() {
        isProfileSetupPending = false
        cachedName = nil
        cachedImageUri = nil
        cachedProfileOwner = nil
        clearAuthenticatedState(clearCachedProfile: false)
    }

    static func markPaykitReconciliationPendingAfterFailedSignOut(
        publicSharingEnabled: Bool,
        privateSharingEnabled: Bool,
        setPublicReconciliationPending: (Bool) -> Void = PublicPaykitService.setCleanupPending,
        setPrivateReconciliationPending: (Bool) -> Void = PrivatePaykitService.setContactSharingCleanupPending
    ) {
        if publicSharingEnabled || privateSharingEnabled {
            setPublicReconciliationPending(true)
        }
        if privateSharingEnabled {
            setPrivateReconciliationPending(true)
        }
    }

    static func clearPaykitSharingAfterProfileDeletion(
        defaults: UserDefaults = .standard,
        setPublicReconciliationPending: (Bool) -> Void = PublicPaykitService.setCleanupPending
    ) {
        let hadPublishedState = defaults.bool(forKey: PublicPaykitService.publishingEnabledKey) ||
            defaults.bool(forKey: PrivatePaykitService.publishingEnabledKey)
        defaults.set(false, forKey: PublicPaykitService.publishingEnabledKey)
        defaults.set(false, forKey: PrivatePaykitService.publishingEnabledKey)
        if hadPublishedState {
            setPublicReconciliationPending(true)
        }
    }

    // MARK: - Cached Profile Metadata

    private static let cachedNameKey = "pubky_profile_name"
    private static let cachedIdentityKey = "pubky_profile_identity"
    private static let cachedImageUriKey = "pubky_profile_image_uri"
    private static let cachedProfileOwnerKey = "pubky_profile_owner"
    private static let profileSetupPendingKey = "pubky_profile_setup_pending"

    var displayName: String? {
        profile?.name ?? cachedName
    }

    var displayImageUri: String? {
        profile?.imageUrl ?? cachedImageUri
    }

    /// A saved credential proves display ownership only, never authentication or permission to write.
    var profileForDisplay: PubkyProfile? {
        profile ?? (hasReadOnlyProfileIdentity ? readOnlyProfile?.profile : nil)
    }

    var publicKeyForDisplay: String? {
        publicKey ?? (hasReadOnlyProfileIdentity ? readOnlyProfile?.publicKey : nil)
    }

    private var hasReadOnlyProfileIdentity: Bool {
        guard readOnlyProfile?.revision == Self.sessionRevision else { return false }
        // Only this Disconnect may retain display ownership; any other identity mutation invalidates it.
        return Self.sessionMutationCount == 0 ||
            (Self.sessionMutationCount == 1 && readOnlySignOutRevision == Self.sessionRevision)
    }

    /// The cached name and avatar for the authenticated or credential-verified display identity. It has no bio, links
    /// or tags, so it must never stand in for `profile`. Nil before initialization and when the cache has no matching owner.
    var cachedProfilePreview: PubkyProfile? {
        guard isInitialized,
              let publicKey = publicKeyForDisplay,
              let cachedName,
              PubkyPublicKeyFormat.matches(cachedProfileOwner, publicKey)
        else { return nil }

        return .forDisplay(publicKey: publicKey, name: cachedName, imageUrl: cachedImageUri)
    }

    private func cacheProfileMetadata(_ profile: PubkyProfile) {
        cachedName = profile.name
        cachedImageUri = profile.imageUrl
        cachedProfileOwner = profile.publicKey
        UserDefaults.standard.set(profile.name, forKey: Self.cachedNameKey)
        UserDefaults.standard.set(profile.imageUrl, forKey: Self.cachedImageUriKey)
        UserDefaults.standard.set(profile.publicKey, forKey: Self.cachedIdentityKey)
        UserDefaults.standard.set(profile.publicKey, forKey: Self.cachedProfileOwnerKey)
    }

    static func activateCachedIdentity(publicKey: String, previousPublicKey: String?) {
        let owner = UserDefaults.standard.string(forKey: cachedIdentityKey) ?? previousPublicKey
        if let owner, !PubkyPublicKeyFormat.matches(owner, publicKey) {
            clearCachedIdentityMetadata()
        }
        UserDefaults.standard.set(publicKey, forKey: cachedIdentityKey)
    }

    static func clearCachedIdentityMetadata() {
        UserDefaults.standard.removeObject(forKey: cachedIdentityKey)
        UserDefaults.standard.removeObject(forKey: cachedNameKey)
        UserDefaults.standard.removeObject(forKey: cachedImageUriKey)
        UserDefaults.standard.removeObject(forKey: cachedProfileOwnerKey)
        ContactsManager.restoreContactProfileOverrides(nil)
    }

    private func reloadCachedProfileMetadata() {
        profile = nil
        cachedName = UserDefaults.standard.string(forKey: Self.cachedNameKey)
        cachedImageUri = UserDefaults.standard.string(forKey: Self.cachedImageUriKey)
        cachedProfileOwner = UserDefaults.standard.string(forKey: Self.cachedProfileOwnerKey)
    }

    private func clearCachedProfileMetadata() {
        cachedName = nil
        cachedImageUri = nil
        cachedProfileOwner = nil
        UserDefaults.standard.removeObject(forKey: Self.cachedNameKey)
        UserDefaults.standard.removeObject(forKey: Self.cachedImageUriKey)
        UserDefaults.standard.removeObject(forKey: Self.cachedIdentityKey)
        UserDefaults.standard.removeObject(forKey: Self.cachedProfileOwnerKey)
    }

    private func setProfileSetupPending(_ pending: Bool) {
        isProfileSetupPending = pending
        UserDefaults.standard.set(pending, forKey: Self.profileSetupPendingKey)
    }

    private func clearAuthenticatedState(clearCachedProfile: Bool = true, clearReadOnlyProfile: Bool = true) {
        // Automatic recovery also lands here while nothing is signed in, which must not discard the choice rows.
        let wasAuthenticated = isAuthenticated
        if clearReadOnlyProfile || wasAuthenticated {
            invalidateProfileLoads()
        }
        publicKey = nil
        profile = nil
        authState = .idle
        if clearReadOnlyProfile {
            readOnlyProfile = nil
        }
        if clearCachedProfile {
            clearCachedProfileMetadata()
        }
        if wasAuthenticated {
            clearRingIdentityProfiles()
        }
    }

    private func activeSessionSecret() throws -> String {
        guard let sessionSecret = try? Keychain.loadString(key: .paykitSession),
              !sessionSecret.isEmpty
        else {
            throw PubkyServiceError.sessionNotActive
        }
        return sessionSecret
    }

    // MARK: - Session & Backup Helpers

    var isAuthenticated: Bool {
        publicKey != nil
    }

    /// The signed-in session as work that started for it saw it. Work that waits compares it with `currentSession`
    /// afterwards to tell whether that session ended or changed meanwhile.
    struct SignedInSession: Equatable {
        let publicKey: String
        fileprivate let revision: UUID
    }

    /// Nil while signed out, and from the moment a sign-in, sign-out or other session change starts until it ends, so
    /// before that change clears any state. The session after a change compares different from the one before.
    var currentSession: SignedInSession? {
        guard removalRecovery == .ready, let publicKey, Self.sessionMutationCount == 0 else { return nil }
        return SignedInSession(publicKey: publicKey, revision: Self.sessionRevision)
    }

    func requireCurrentSession(_ session: SignedInSession) throws {
        try Task.checkCancellation()
        guard currentSession == session else { throw PubkyServiceError.identityChanged }
    }

    var automaticPaykitSession: SignedInSession? {
        guard authState == .authenticated, !isDeletingProfile else { return nil }
        return currentSession
    }

    /// Automatic work announced inside a transition must inherit its next ordinary scope, not its expiring token.
    func scheduleAutomaticPaykitSession(_ operation: @escaping @MainActor (SignedInSession) async -> Void) throws {
        guard let session = automaticPaykitSession else { return }
        let admission = removalAdmission
        try admission.scheduleAfterTransition { scope in
            Task { @MainActor [weak self] in
                defer { admission.release(scope) }
                do {
                    try await admission.withScope(scope) {
                        guard let self, self.automaticPaykitSession == session else { return }
                        await operation(session)
                    }
                } catch {
                    Logger.debug("Automatic Paykit startup stopped: \(error)", context: "PubkyProfileManager")
                }
            }
        }
    }

    func storedIdentityGuard() -> (@MainActor () -> Bool)? {
        guard !isAuthenticated, Self.sessionMutationCount == 0, (try? Self.hasStoredIdentity()) == true else { return nil }
        let revision = Self.sessionRevision
        // Restoration keeps this revision; identity replacement and sign-out invalidate it.
        return { [weak self] in
            self != nil && Self.sessionMutationCount == 0 && Self.sessionRevision == revision
        }
    }

    var hasLocalSecretKeyForCurrentProfile: Bool {
        Self.hasLocalSecretKey(for: publicKey)
    }

    /// The signed-in pubky is Pubky Ring's, adopted through the shared keychain, so removing it here only unlinks it.
    var isRingAdoptedIdentity: Bool {
        guard let adopted = AdoptedPubkyReference.current, adopted.sourceApp == SharedPubkyKeychain.ringSourceApp else {
            return false
        }
        return PubkyPublicKeyFormat.matches(adopted.pubky, publicKey)
    }

    nonisolated static func hasStoredIdentityForBackup() throws -> Bool {
        try ProfileRemovalStore.shared.requireNoPending()
        if AdoptedPubkyReference.current != nil {
            return true
        }
        // Malformed credential bytes must not permit an identity-free replacement backup.
        return try [KeychainEntryType.paykitSession, .pubkySecretKey].contains {
            try Keychain.load(key: $0)?.isEmpty == false
        }
    }

    nonisolated static func hasStoredIdentity(
        adopted: (sourceApp: String, pubky: String)? = AdoptedPubkyReference.current
    ) throws -> Bool {
        // The next launch signs in again with an adopted Ring key, so its reference counts as an identity.
        if adopted != nil {
            return true
        }

        for key in [KeychainEntryType.paykitSession, .pubkySecretKey] {
            if let value = try Keychain.loadString(key: key), !value.isEmpty {
                return true
            }
        }
        return false
    }

    /// The secret key to sign with: Bitkit's own if it has one, otherwise the adopted app's, read just-in-time.
    nonisolated static func activeSecretKeyHex(
        loadKeychainString: (KeychainEntryType) throws -> String? = {
            try Keychain.loadString(key: $0)
        },
        adopted: (sourceApp: String, pubky: String)? = AdoptedPubkyReference.current,
        loadSharedSecret: (String, String) -> String? = SharedPubkyKeychain.loadSecret
    ) -> String? {
        if let secretKeyHex = try? loadKeychainString(.pubkySecretKey), !secretKeyHex.isEmpty {
            return secretKeyHex
        }

        guard let adopted else {
            return nil
        }

        return loadSharedSecret(adopted.sourceApp, adopted.pubky)
    }

    nonisolated static func hasLocalSecretKey(for publicKey: String?) -> Bool {
        guard let publicKey,
              let secretKeyHex = activeSecretKeyHex(),
              let rawPublicKey = try? PubkyService.pubkyPublicKeyFromSecret(secretKeyHex: secretKeyHex)
        else {
            return false
        }

        let prefixedPublicKey = rawPublicKey.hasPrefix("pubky") ? rawPublicKey : "pubky\(rawPublicKey)"
        return PubkyPublicKeyFormat.matches(prefixedPublicKey, publicKey)
    }

    nonisolated static func hasPrivatePaymentAccess(
        for publicKey: String?,
        loadKeychainString: (KeychainEntryType) throws -> String? = {
            guard let data = try Keychain.load(key: $0) else { return nil }
            guard let value = String(data: data, encoding: .utf8) else { throw KeychainError.failedToLoad }
            return value
        },
        adopted: (sourceApp: String, pubky: String)? = AdoptedPubkyReference.current,
        loadSharedSecret: (String, String) throws -> String? = {
            try SharedPubkyKeychain.readSecret(sourceApp: $0, pubky: $1)
        }
    ) throws -> Bool {
        guard let publicKey else { return false }
        let secretKeyHex: String? = if let localSecret = try loadKeychainString(.pubkySecretKey), !localSecret.isEmpty {
            localSecret
        } else if let adopted {
            try loadSharedSecret(adopted.sourceApp, adopted.pubky)
        } else {
            nil
        }
        guard let secretKeyHex else { return false }
        let rawPublicKey = try PubkyService.pubkyPublicKeyFromSecret(secretKeyHex: secretKeyHex)
        let prefixedPublicKey = rawPublicKey.hasPrefix("pubky") ? rawPublicKey : "pubky\(rawPublicKey)"
        return PubkyPublicKeyFormat.matches(prefixedPublicKey, publicKey)
    }

    nonisolated static func snapshotSessionBackupState(
        loadKeychainString: (KeychainEntryType) throws -> String? = {
            try Keychain.loadString(key: $0)
        },
        adopted: (sourceApp: String, pubky: String)? = AdoptedPubkyReference.current
    ) throws -> PubkySessionBackupV1? {
        // A foreign key stays with its owner, so an adopted identity has nothing to back up.
        guard adopted == nil, let secretKeyHex = try loadKeychainString(.pubkySecretKey), !secretKeyHex.isEmpty else {
            return nil
        }

        return PubkySessionBackupV1(kind: .localSeed)
    }

    nonisolated static func restoreSessionBackupState(
        _ backup: PubkySessionBackupV1?,
        loadKeychainString: (KeychainEntryType) throws -> String? = {
            try Keychain.loadString(key: $0)
        },
        persistKeychainString: (KeychainEntryType, String) throws -> Void = { key, value in
            guard let data = value.data(using: .utf8) else {
                throw KeychainError.failedToSave
            }
            try Keychain.upsert(key: key, data: data)
        },
        deleteKeychainValue: (KeychainEntryType) throws -> Void = {
            try Keychain.delete(key: $0)
        },
        removeOwnSharedRecords: () throws -> Void = {
            try SharedPubkyKeychain.removeAllOwnOrThrow()
        },
        forgetSessionAccess: @escaping () async throws -> Void = {
            try await PubkyService.forgetSessionAccess()
        },
        signInWithSecretKey: @escaping (String) async throws -> String = {
            try await PubkyService.signIn(secretKeyHex: $0)
        }
    ) async throws {
        return try await ProfileOperationAdmission.shared.withSessionTransition {
            try await beginSessionMutation()
            do {
                let secretKeyHex: String?
                do {
                    try await forgetSessionAccess()
                    try ProfileOperationAdmission.shared.checkCurrent()
                    try deleteKeychainValue(.paykitSession)
                    try deleteKeychainValue(.pubkySecretKey)
                    try removeOwnSharedRecords()
                    switch backup?.kind {
                    case .none:
                        secretKeyHex = nil
                    case .localSeed:
                        let derived = try deriveLocalSecretKeyFromWalletSeed(loadKeychainString: loadKeychainString)
                        try persistKeychainString(.pubkySecretKey, derived)
                        secretKeyHex = derived
                    }
                } catch {
                    throw ProfileSessionRestoreLocalError(underlyingError: error)
                }
                if let secretKeyHex {
                    // Remote authorization stays awaited, after every required local replacement has acknowledged.
                    _ = try await signInWithSecretKey(secretKeyHex)
                    try ProfileOperationAdmission.shared.checkCurrent()
                }
            } catch {
                await endSessionMutation()
                throw error
            }
            await endSessionMutation()
        }
    }

    private nonisolated static func initializePersistedSession() async throws -> SessionInitializationResult {
        try await PaykitSdkService.shared.restorePersistedSession()
    }

    private nonisolated static func notifyAppStateBackupChanged() {
        Task { @MainActor in
            SettingsViewModel.shared.notifyAppStateChanged()
        }
    }

    private nonisolated static func deriveLocalSecretKeyFromWalletSeed(
        loadKeychainString: (KeychainEntryType) throws -> String? = {
            try Keychain.loadString(key: $0)
        }
    ) throws -> String {
        guard let mnemonic = try loadKeychainString(.bip39Mnemonic(index: 0)),
              !mnemonic.isEmpty
        else {
            throw PubkyServiceError.authFailed("Mnemonic not found")
        }

        return try PubkyService.derivePubkySecretKey(mnemonic: mnemonic)
    }

    nonisolated static func publicKeyFromSecretKey(_ secretKeyHex: String) throws -> String {
        let publicKey = try PubkyService.pubkyPublicKeyFromSecret(secretKeyHex: secretKeyHex)
        guard let normalized = PubkyPublicKeyFormat.normalized(publicKey) else {
            throw PubkyServiceError.authFailed("Invalid Pubky public key")
        }
        return normalized
    }

    nonisolated static func resolveSessionInitialization(
        savedSessionSecret: String?,
        storedSecretKeyHex: String?,
        importSession: (String) async throws -> String,
        signInWithSecretKey: (String) async throws -> String,
        publicKeyFromSecretKey: (String) throws -> String = {
            try PubkyProfileManager.publicKeyFromSecretKey($0)
        }
    ) async -> SessionInitializationResult {
        if let savedSessionSecret,
           !savedSessionSecret.isEmpty
        {
            do {
                let publicKey = try await importSession(savedSessionSecret)
                return .restored(publicKey: publicKey)
            } catch {
                if isTemporarySessionRestorationError(error) {
                    Logger.warn("Deferred session restoration, keeping saved session", context: "PubkyProfileManager")
                    return .restorationDeferred
                }
                Logger.warn("Failed to import saved session, attempting re-sign-in: \(error)", context: "PubkyProfileManager")
            }
        }

        guard let storedSecretKeyHex,
              !storedSecretKeyHex.isEmpty
        else {
            if let savedSessionSecret,
               !savedSessionSecret.isEmpty
            {
                // A session without a reachable secret key cannot be re-established, so keep it for a later retry.
                Logger.warn("No secret key to recover session", context: "PubkyProfileManager")
                return .restorationFailed
            }

            return .noSession
        }

        do {
            _ = try await signInWithSecretKey(storedSecretKeyHex)
            let publicKey = try publicKeyFromSecretKey(storedSecretKeyHex)
            Logger.info("Re-signed in and restored session for \(publicKey)", context: "PubkyProfileManager")
            return .restored(publicKey: publicKey)
        } catch {
            Logger.warn("Re-sign-in failed, keeping saved session for retry: \(error)", context: "PubkyProfileManager")
            return isTemporarySessionRestorationError(error) ? .restorationDeferred : .restorationFailed
        }
    }

    private nonisolated static func isTemporarySessionRestorationError(_ error: Error) -> Bool {
        switch error {
        case is CancellationError, PaykitError.ConcurrentUpdate, PaykitError.SharedStateBusy, PaykitError.Transport:
            return true
        default:
            return false
        }
    }
}

struct ProfileSessionRestoreLocalError: Error {
    let underlyingError: Error
}
