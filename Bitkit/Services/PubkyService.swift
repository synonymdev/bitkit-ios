import BitkitCore
import Combine
import Foundation
import Paykit

enum PubkyServiceError: LocalizedError {
    case invalidAuthUrl
    case sessionNotActive
    case authFailed(String)
    case profileNotFound
    case activeSubscription(endsAt: Date?)
    /// A write was for an identity that is no longer the signed-in one, so it wrote nothing.
    case identityChanged

    var errorDescription: String? {
        switch self {
        case .invalidAuthUrl:
            return "Failed to generate auth URL"
        case .sessionNotActive:
            return "No active Pubky session"
        case let .authFailed(reason):
            return "Authentication failed: \(reason)"
        case .profileNotFound:
            return "Profile not found"
        case .activeSubscription:
            return "Contact has an active subscription"
        case .identityChanged:
            return "The Pubky identity changed"
        }
    }
}

struct PubkyRegisteredIdentity {
    let result: PubkySessionBootstrapResult
    let walletGeneration: Int
}

/// Which public read slots a read may use. Background work that reads for many contacts at once is `bulk`, so it can
/// never take every read slot from reads for what the user is looking at, and a freed read slot goes to those reads
/// first. Reads the user is waiting on are `interactive` even when there are many of them, such as the follow lookups
/// that prepare a contact import.
enum PaykitPublicReadPriority {
    case interactive
    case bulk
}

/// Service layer for Pubky sessions, profiles, contacts, and Paykit SDK workflows.
enum PubkyService {
    static func initialize() async throws {
        try await PaykitSdkService.shared.initialize()
    }

    static func republishIdentityIfNeeded(publicKey: String? = nil) async {
        await PaykitSdkService.shared.republishIdentityIfNeeded(publicKey: publicKey)
    }

    static func hasIdentityRecord(publicKey: String) async throws -> Bool {
        try await PaykitSdkService.shared.hasIdentityRecord(publicKey: publicKey)
    }

    // MARK: - Session Management

    /// Import a session secret into paykit and return the public key.
    static func importSession(secret: String) async throws -> String {
        let result = try await PaykitSdkService.shared.importSession(secret: secret)
        return result.publicKey
    }

    static func currentPublicKey() async -> String? {
        try? await PaykitSdkService.shared.currentPublicKey()
    }

    // MARK: - Auth Approval (Bitkit as authenticator)

    /// Parse a pubkyauth:// URL to extract details for UI display.
    static func parseAuthUrl(_ authUrl: String) throws -> Paykit.PubkyAuthDetails {
        try Paykit.parsePubkyAuthUrl(authUrl: authUrl)
    }

    /// Approve a pubkyauth:// request using the local secret key.
    static func approveAuth(
        authUrl: String,
        expectedCapabilities: String,
        approvedClientID: String,
        secretKeyHex: String,
        sdkService: PaykitSdkService = .shared
    ) async throws {
        try await sdkService.republishIdentityBeforeApproval(publicKey: pubkyPublicKeyFromSecret(secretKeyHex: secretKeyHex))
        try Task.checkCancellation()
        try await sdkService.approveAuth(
            authUrl: authUrl,
            expectedCapabilities: expectedCapabilities,
            approvedClientID: approvedClientID,
            secretKeyHex: secretKeyHex
        )
    }

    static func approveRingAuth(authUrl: String, secretKeyHex: String, sdkService: PaykitSdkService = .shared) async throws {
        try await sdkService.republishIdentityBeforeApproval(publicKey: pubkyPublicKeyFromSecret(secretKeyHex: secretKeyHex))
        try Task.checkCancellation()
        try await ServiceQueue.background(.core) {
            try await BitkitCore.approvePubkyAuth(authUrl: authUrl, secretKeyHex: secretKeyHex)
        }
    }

    static func approveAuthWithCompanionClaim(
        authUrl: String,
        approvedClientID: String,
        claim: PubkyAuthClaim,
        accountPayload: Data?,
        secretKeyHex: String,
        sdkService: PaykitSdkService = .shared
    ) async throws {
        try await sdkService.republishIdentityBeforeApproval(publicKey: pubkyPublicKeyFromSecret(secretKeyHex: secretKeyHex))
        try Task.checkCancellation()
        let paykitKey = claim.includesPaykitAccess
            ? try await sdkService.paykitKeyForAuthorization(secretKeyHex: secretKeyHex)
            : nil
        let payload = try claim.encode(accountPayload: accountPayload, paykitKey: paykitKey)
        try await sdkService.approveAuthWithCompanionClaim(
            authUrl: authUrl,
            expectedCapabilities: PubkyAuthClaim.requiredCapabilities,
            approvedClientID: approvedClientID,
            secretKeyHex: secretKeyHex,
            claim: Paykit.PubkyAuthCompanionClaim(
                queryParameter: PubkyAuthClaim.queryParameter,
                claimType: claim.rawValue,
                unsignedPayload: payload
            )
        )
    }

    static func didDeliverCompanionClaim(error: Error) -> Bool {
        guard let approvalError = error as? Paykit.PubkyAuthCompanionClaimApprovalError else { return false }
        // Paykit documents AuthorizationFailure as the post-delivery case; unknown errors do not imply delivery.
        if case .AuthorizationFailure = approvalError {
            return true
        }
        return false
    }

    typealias OrdinaryAuthApproval = (String, String, String, String) async throws -> Void
    typealias CompanionAuthApproval = (String, String, PubkyAuthClaim, Data?, String) async throws -> Void

    @MainActor
    static func approveAuthRequest(
        request: PubkyAuthRequest,
        authUrl: String,
        accountName: String,
        secretKeyHex: String,
        accountManager: WatchOnlyAccountManager? = nil,
        ordinaryApproval: @escaping OrdinaryAuthApproval = { authUrl, capabilities, clientID, secretKeyHex in
            try await approveAuth(
                authUrl: authUrl,
                expectedCapabilities: capabilities,
                approvedClientID: clientID,
                secretKeyHex: secretKeyHex
            )
        },
        companionApproval: @escaping CompanionAuthApproval = { authUrl, clientID, claim, accountPayload, secretKeyHex in
            try await approveAuthWithCompanionClaim(
                authUrl: authUrl,
                approvedClientID: clientID,
                claim: claim,
                accountPayload: accountPayload,
                secretKeyHex: secretKeyHex
            )
        }
    ) async throws {
        guard authUrl == request.rawUrl else { throw PubkyServiceError.invalidAuthUrl }
        if let claim = request.bitkitClaim, claim.includesWatchOnlyAccount {
            let accountManager = accountManager ?? .shared
            let preparedClaim = try await accountManager.prepareUnsignedClaim(
                authUrl: authUrl, name: accountName
            )
            let authorizationAttempt = try accountManager.acquireSetupAuthorizationAttempt(id: preparedClaim.0.id)
            defer { accountManager.finishSetupAuthorizationAttempt(authorizationAttempt) }

            do {
                try await accountManager.beginSetupAuthorization(attempt: authorizationAttempt)
            } catch {
                await cancelIncompleteAuthorization(
                    accountManager: accountManager,
                    authorizationAttempt: authorizationAttempt
                )
                throw error
            }

            do {
                try await companionApproval(authUrl, request.clientID, claim, preparedClaim.1, secretKeyHex)
            } catch {
                if !didDeliverCompanionClaim(error: error) {
                    await cancelIncompleteAuthorization(
                        accountManager: accountManager,
                        authorizationAttempt: authorizationAttempt
                    )
                }
                throw error
            }

            try await accountManager.markSetupActive(attempt: authorizationAttempt)
        } else if let claim = request.bitkitClaim {
            try await companionApproval(authUrl, request.clientID, claim, nil, secretKeyHex)
        } else {
            try await ordinaryApproval(authUrl, request.capabilities, request.clientID, secretKeyHex)
        }
    }

    @MainActor
    private static func cancelIncompleteAuthorization(
        accountManager: WatchOnlyAccountManager,
        authorizationAttempt: WatchOnlyAccountAuthorizationAttempt
    ) async {
        do {
            try await accountManager.cancelSetupAuthorization(attempt: authorizationAttempt)
        } catch {
            Logger.error("Failed to unload incomplete watch-only account: \(error)", context: "PubkyService")
        }
    }

    // MARK: - Key Derivation

    /// Derive an Ed25519 secret key from a BIP39 mnemonic. Returns hex-encoded 32-byte key.
    static func derivePubkySecretKey(mnemonic: String) throws -> String {
        let secretKey = try Paykit.pubkySecretKeyFromBip39Mnemonic(mnemonicPhrase: mnemonic)
        return PaykitSdkService.secretKeyHex(from: secretKey)
    }

    /// Derive the z32-encoded public key from a hex-encoded secret key.
    static func pubkyPublicKeyFromSecret(secretKeyHex: String) throws -> String {
        try Paykit.pubkyPublicKeyFromSecret(localSecretKey: PaykitSdkService.localSecretKey(fromHex: secretKeyHex))
    }

    // MARK: - Homeserver Auth

    /// Sign up on a homeserver. Returns session secret for persistence.
    static func signUp(secretKeyHex: String, homeserverZ32: String, signupCode: String? = nil) async throws -> String {
        let result = try await PaykitSdkService.shared.signUp(
            secretKeyHex: secretKeyHex,
            homeserverPublicKey: homeserverZ32,
            signupCode: signupCode
        )
        return result.sessionAccess.exportSessionSecret()
    }

    static func registerIdentity(
        secretKeyHex: String,
        homeserverZ32: String,
        signupCode: String? = nil
    ) async throws -> PubkyRegisteredIdentity {
        try await PaykitSdkService.shared.registerIdentity(
            secretKeyHex: secretKeyHex,
            homeserverPublicKey: homeserverZ32,
            signupCode: signupCode
        )
    }

    static func activateRegisteredIdentity(_ identity: PubkyRegisteredIdentity) async throws {
        try await PaykitSdkService.shared.activateRegisteredIdentity(identity)
    }

    /// Sign in with an existing secret key. Returns new session secret.
    static func signIn(secretKeyHex: String) async throws -> String {
        let result = try await PaykitSdkService.shared.signIn(secretKeyHex: secretKeyHex)
        return result.sessionAccess.exportSessionSecret()
    }

    // MARK: - File Fetching

    /// Fetch raw bytes from a `pubky://` URI via PKDNS resolution.
    static func fetchFile(uri: String, maxBytes: UInt64) async throws -> Data {
        try await PaykitSdkService.shared.fetchFile(uri: uri, maxBytes: maxBytes)
    }

    // MARK: - Profile

    static func publishPaykitProfile(_ profile: Paykit.PaykitProfile, expectedIdentity: String? = nil) async throws {
        _ = try await PaykitSdkService.shared.publishPaykitProfile(profile, expectedIdentity: expectedIdentity)
    }

    static func uploadProfileAvatar(bytes: Data, contentType: String, expectedIdentity: String? = nil) async throws -> String {
        try await PaykitSdkService.shared.uploadAvatar(bytes: bytes, contentType: contentType, expectedIdentity: expectedIdentity)
    }

    static func deletePaykitProfile() async throws {
        try await PaykitSdkService.shared.deletePaykitProfile()
    }

    // MARK: - Contacts

    static func getContacts(publicKey: String) async throws -> [String] {
        try await PaykitSdkService.shared.fetchPubkyFollows(publicKey: publicKey)
    }

    static func contactRecords() async throws -> [Paykit.ContactRecord] {
        try await PaykitSdkService.shared.contactRecords()
    }

    static func saveContact(publicKey: String, label: String?,
                            restorePrivateConnection: Bool = false, expectedIdentity: String? = nil) async throws -> Paykit.ContactRecord
    {
        try await PaykitSdkService.shared.saveContact(
            publicKey: publicKey,
            label: label,
            restorePrivateConnection: restorePrivateConnection,
            expectedIdentity: expectedIdentity
        )
    }

    static func saveContacts(updates: [Paykit.ContactUpdate], expectedIdentity: String? = nil) async throws -> [Paykit.ContactRecord] {
        try await PaykitSdkService.shared.saveContacts(updates: updates, expectedIdentity: expectedIdentity)
    }

    static func removeContact(publicKey: String) async throws -> Paykit.ContactRecord? {
        try await PaykitSdkService.shared.removeContact(publicKey: publicKey)
    }

    static func removeContacts(publicKeys: [String]) async throws -> [Paykit.ContactRecord] {
        try await PaykitSdkService.shared.removeContacts(publicKeys: publicKeys)
    }

    static func resolveContactProfile(
        publicKey: String,
        allowPubkyProfileFallback: Bool,
        priority: PaykitPublicReadPriority = .interactive
    ) async throws -> Paykit.ProfileResolution? {
        try await PaykitSdkService.shared.resolveContactProfile(
            publicKey: publicKey,
            allowPubkyProfileFallback: allowPubkyProfileFallback,
            priority: priority
        )
    }

    // MARK: - Sign Out

    static func signOut() async throws {
        try await PaykitSdkService.shared.signOut()
    }

    static func forgetSessionAccess() async throws {
        try await PaykitSdkService.shared.forgetSessionAccess()
    }
}

// MARK: - Paykit SDK Runtime

actor PaykitSdkService {
    typealias BootstrapFactory = (String, PubkyClientConfig) throws -> PubkySessionBootstrap

    struct BackupStateSnapshot {
        let stateRevision: String
        let backupRevision: String
    }

    static let shared = PaykitSdkService()
    private static let walletBackupDataChangedSubject = PassthroughSubject<Void, Never>()

    nonisolated static var walletBackupDataChangedPublisher: AnyPublisher<Void, Never> {
        walletBackupDataChangedSubject.eraseToAnyPublisher()
    }

    private let sessionProvider = PaykitSdkSessionProvider()
    private let paymentAdapter = PaykitSdkPaymentAdapter()
    private let operationLock = PaykitSdkOperationLock()
    private let publicReadSlots = PaykitPublicReadSlots()
    private let pubkyClientConfig = PaykitSdkService.makePubkyClientConfig(localTestnetHost: Env.pubkyLocalTestnetHost)
    private let sdkFactory: (() throws -> PaykitSdk)?
    private let bootstrapFactory: BootstrapFactory
    private var cachedBootstrap: PubkySessionBootstrap?
    private var isRepublishingIdentity = false
    /// The normalized identity the running publication is for, so an approval signing with it can wait for it.
    private var republishingIdentity: String?
    private var republishWaiters: [AsyncStream<Void>.Continuation] = []
    private var republishPublicKey: String?
    private var nextIdentityRepublishAt = Date.distantPast
    private var lastIdentityRepublishAt = Date.distantPast
    private var sdk: PaykitSdk?
    private var cachedPaykitKey: (publicKey: String, generation: UInt64)?
    private var cachedBackupState: BackupStateSnapshot?

    init(
        sdkFactory: (() throws -> PaykitSdk)? = nil,
        bootstrapFactory: @escaping BootstrapFactory = PubkySessionBootstrap.withPubkyClientConfig(clientId:pubkyClient:)
    ) {
        self.sdkFactory = sdkFactory
        self.bootstrapFactory = bootstrapFactory
    }

    func initialize() async throws {
        startIdentityRepublish()
        try await operationLock.withLock {
            try await initializeLocked()
        }
    }

    private func initializeLocked() async throws {
        try await refreshPaykitKey(force: true)
        var sdk = try handle()
        let status: IdentityStatus
        do {
            status = try await sdk.initialize()
        } catch {
            invalidatePaykitKeyIfNeeded(after: error)
            guard try sessionProvider.canDeferStaleSession(error: error) else { throw error }

            Logger.warn("Deferring stale Paykit session restoration until SDK setup completes", context: "PaykitSdkService")
            sessionProvider.suspendStoredSessionAccess()
            resetRuntime()
            do {
                sdk = try handle()
                status = try await sdk.initialize()
            } catch {
                sessionProvider.resumeStoredSessionAccess()
                throw error
            }
            sessionProvider.resumeStoredSessionAccess()
        }
        await publishAppIfLiveSessionAvailable(using: sdk, status: status)
    }

    /// Keep credential reads and fallback activation atomic with sign-out and identity changes.
    func restorePersistedSession() async throws -> PubkyProfileManager.SessionInitializationResult {
        Task { await republishIdentityIfNeeded() }
        return try await operationLock.withLock {
            let savedSessionSecret = try Keychain.loadString(key: .paykitSession)
            let storedSecretKeyHex = PubkyProfileManager.activeSecretKeyHex()
            if savedSessionSecret == nil, storedSecretKeyHex == nil {
                try await initializeLocked()
            }
            return await PubkyProfileManager.resolveSessionInitialization(
                savedSessionSecret: savedSessionSecret,
                storedSecretKeyHex: storedSecretKeyHex,
                importSession: { try await self.importSessionLocked(secret: $0).publicKey },
                signInWithSecretKey: { try await self.signInLocked(secretKeyHex: $0).publicKey }
            )
        }
    }

    /// Republishes without making the caller wait on the DHT. Only the public key string reaches the task, so it never
    /// keeps session access alive.
    func startIdentityRepublish(publicKey: String? = nil) {
        Task { await republishIdentityIfNeeded(publicKey: publicKey) }
    }

    func republishIdentityIfNeeded(publicKey: String? = nil, now: Date = Date(), timeout: Duration = .seconds(5)) async {
        guard !Task.isCancelled else { return }
        // Swift FFI may ignore cancellation; keep the in-flight guard until publication actually finishes.
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let publication = Task {
            await republishIdentity(publicKey: publicKey, now: now)
            continuation.finish()
        }
        defer { publication.cancel() }
        await waitForRepublish(stream, finishedBy: continuation, timeout: timeout)
    }

    /// For auth approvals. Background triggers skip a publication that is already running, but an approval must still
    /// follow its signing identity's publication, such as the one sign-in starts without waiting, so it waits for that
    /// one under the same cap instead.
    func republishIdentityBeforeApproval(publicKey: String, timeout: Duration = .seconds(5)) async {
        guard !Task.isCancelled else { return }
        guard let runningIdentity = republishingIdentity, runningIdentity == PubkyPublicKeyFormat.normalized(publicKey) else {
            await republishIdentityIfNeeded(publicKey: publicKey, timeout: timeout)
            return
        }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        republishWaiters.append(continuation)
        await waitForRepublish(stream, finishedBy: continuation, timeout: timeout)
    }

    private func waitForRepublish(
        _ stream: AsyncStream<Void>,
        finishedBy continuation: AsyncStream<Void>.Continuation,
        timeout: Duration
    ) async {
        let deadline = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            Logger.warn("Stopped waiting for Pubky identity republishing", context: "PaykitSdkService")
            continuation.finish()
        }
        defer {
            deadline.cancel()
            continuation.finish()
        }
        for await _ in stream {}
    }

    /// Rebroadcasts the identity record when one exists. Returns false only when the network reports none.
    func hasIdentityRecord(publicKey: String) async throws -> Bool {
        try await bootstrap().republishIdentity(publicKey: publicKey)
    }

    private func republishIdentity(publicKey: String?, now: Date) async {
        guard !Task.isCancelled, !isRepublishingIdentity else { return }
        isRepublishingIdentity = true
        defer {
            isRepublishingIdentity = false
            republishingIdentity = nil
            republishWaiters.forEach { $0.finish() }
            republishWaiters.removeAll()
        }

        do {
            let identity = try publicKey ?? sessionProvider.loadLocalSecretKey().map {
                try Paykit.pubkyPublicKeyFromSecret(localSecretKey: $0)
            }
            guard let identity = identity.flatMap(PubkyPublicKeyFormat.normalized),
                  identity != republishPublicKey || now < lastIdentityRepublishAt || now >= nextIdentityRepublishAt
            else { return }

            republishPublicKey = identity
            lastIdentityRepublishAt = now
            nextIdentityRepublishAt = now.addingTimeInterval(60)
            republishingIdentity = identity
            if try await bootstrap().republishIdentity(publicKey: identity) {
                nextIdentityRepublishAt = now.addingTimeInterval(30 * 60)
                Logger.debug("Republished Pubky identity", context: "PaykitSdkService")
            } else {
                Logger.debug("Found no Pubky identity record to republish", context: "PaykitSdkService")
            }
        } catch is CancellationError {
        } catch {
            Logger.warn("Failed to republish Pubky identity: \(error)", context: "PaykitSdkService")
        }
    }

    func currentPublicKey() async throws -> String? {
        try await withSdk { sdk in
            if let status = try await sdk.identityStatus(), let publicKey = status.publicKey {
                return publicKey
            }

            guard let publicKey = try await sdk.initialize().publicKey else {
                return nil
            }

            return publicKey
        }
    }

    func identityStatus() async throws -> IdentityStatus? {
        try await identityStatus(priority: .ordered)
    }

    func identityStatus(priority: PaykitSdkOperationLock.Priority) async throws -> IdentityStatus? {
        try await withSdk(priority: priority) { sdk in
            try await sdk.identityStatus()
        }
    }

    func importSession(secret: String) async throws -> PubkySessionBootstrapResult {
        try await operationLock.withLock {
            try await importSessionLocked(secret: secret)
        }
    }

    private func importSessionLocked(secret: String) async throws -> PubkySessionBootstrapResult {
        let previousPublicKey = try await cachedIdentityPublicKey()
        let localSecret = try sessionProvider.loadLocalSecretKey()
        let result = try await bootstrap().importSession(
            sessionSecret: secret,
            localSecretKey: localSecret,
            requiredCapabilities: Self.requiredCapabilities()
        )
        try await activateBootstrapResult(result, previousPublicKey: previousPublicKey)
        markWalletBackupDataChanged()
        return result
    }

    func signUp(secretKeyHex: String, homeserverPublicKey: String, signupCode: String?) async throws -> PubkySessionBootstrapResult {
        try await operationLock.withLock {
            let previousPublicKey = try await cachedIdentityPublicKey()
            let result = try await bootstrap().signUp(
                localSecretKey: Self.localSecretKey(fromHex: secretKeyHex),
                homeserverPublicKey: homeserverPublicKey,
                signupCode: signupCode,
                requiredCapabilities: Self.requiredCapabilities()
            )
            try await activateBootstrapResult(result, previousPublicKey: previousPublicKey)
            markWalletBackupDataChanged()
            return result
        }
    }

    func registerIdentity(
        secretKeyHex: String,
        homeserverPublicKey: String,
        signupCode: String?
    ) async throws -> PubkyRegisteredIdentity {
        try await operationLock.withLock {
            let generation = try operationLock.walletGeneration()
            let result = try await bootstrap().signUp(
                localSecretKey: Self.localSecretKey(fromHex: secretKeyHex),
                homeserverPublicKey: homeserverPublicKey,
                signupCode: signupCode,
                requiredCapabilities: Self.requiredCapabilities()
            )
            return PubkyRegisteredIdentity(result: result, walletGeneration: generation)
        }
    }

    func activateRegisteredIdentity(_ identity: PubkyRegisteredIdentity) async throws {
        try await operationLock.withLock(generation: identity.walletGeneration) {
            let previousPublicKey = try await cachedIdentityPublicKey()
            try await activateBootstrapResult(identity.result, previousPublicKey: previousPublicKey)
            markWalletBackupDataChanged()
        }
    }

    func signIn(secretKeyHex: String) async throws -> PubkySessionBootstrapResult {
        try await operationLock.withLock {
            try await signInLocked(secretKeyHex: secretKeyHex)
        }
    }

    private func signInLocked(secretKeyHex: String) async throws -> PubkySessionBootstrapResult {
        let previousPublicKey = try await cachedIdentityPublicKey()
        let result = try await bootstrap().signIn(
            localSecretKey: Self.localSecretKey(fromHex: secretKeyHex),
            requiredCapabilities: Self.requiredCapabilities()
        )
        try await activateBootstrapResult(result, previousPublicKey: previousPublicKey)
        markWalletBackupDataChanged()
        return result
    }

    func approveAuth(authUrl: String, expectedCapabilities: String, approvedClientID: String, secretKeyHex: String) async throws {
        try await operationLock.withLock {
            try await approvalBootstrap(authUrl: authUrl, approvedClientID: approvedClientID).approveAuth(
                authUrl: authUrl,
                expectedCapabilities: expectedCapabilities,
                localSecretKey: Self.localSecretKey(fromHex: secretKeyHex)
            )
        }
    }

    func approveAuthWithCompanionClaim(
        authUrl: String,
        expectedCapabilities: String,
        approvedClientID: String,
        secretKeyHex: String,
        claim: Paykit.PubkyAuthCompanionClaim
    ) async throws {
        try await operationLock.withLock {
            try await approvalBootstrap(authUrl: authUrl, approvedClientID: approvedClientID).approveAuthWithCompanionClaim(
                authUrl: authUrl,
                expectedCapabilities: expectedCapabilities,
                localSecretKey: Self.localSecretKey(fromHex: secretKeyHex),
                claim: claim
            )
        }
    }

    func fetchFile(uri: String, maxBytes: UInt64) async throws -> Data {
        guard let data = try await withPublicRead({ try await $0.fetchPubkyFileBounded(uri: uri, maxBytes: maxBytes) }) else {
            throw PubkyServiceError.profileNotFound
        }
        return data
    }

    /// With `expectedIdentity`, it publishes only while that identity is signed in, checked in the same locked operation as
    /// the publication, so one that a sign-out or another identity's sign-in overtakes writes nothing and throws
    /// `identityChanged`.
    func publishPaykitProfile(_ profile: Paykit.PaykitProfile, expectedIdentity: String? = nil) async throws -> Paykit.PaykitProfileRecord {
        try await withStateRevisionTracking { sdk in
            if let expectedIdentity {
                try await Self.requireSignedInIdentity(expectedIdentity, in: sdk)
            }
            guard let publicKey = try await sdk.identityStatus()?.publicKey else { throw PubkyServiceError.sessionNotActive }
            let current = try await sdk.fetchPaykitProfile(publicKey: publicKey)
            return try await sdk.publishPaykitProfile(profile: profile, expectedRevision: current?.revision)
        }
    }

    /// The upload for payment requests, such as a subscription icon. With `expectedIdentity`, it throws
    /// `requestUnavailable` unless that identity is signed in with a live session.
    func uploadProfileAvatar(bytes: Data, contentType: String, expectedIdentity: String? = nil) async throws -> String {
        let record = try await withStateRevisionTracking { sdk in
            if let expectedIdentity {
                guard let identity = try await sdk.identityStatus(),
                      identity.capability == .publicOnly || identity.capability == .privateLinkCapable,
                      PubkyPublicKeyFormat.matches(identity.publicKey, expectedIdentity)
                else { throw PaykitPaymentRequestError.requestUnavailable }
            }
            return try await sdk.uploadProfileAvatar(bytes: bytes, contentType: contentType)
        }
        return record.uri
    }

    /// The upload for profile and contact avatars. With `expectedIdentity`, it uploads only while that identity is signed
    /// in, checked in the same locked operation as the upload, so one that a sign-out or another identity's sign-in
    /// overtakes writes nothing and throws `identityChanged`. Any other failure, such as having no live session, is the
    /// SDK's own error.
    func uploadAvatar(bytes: Data, contentType: String, expectedIdentity: String?) async throws -> String {
        let record = try await withStateRevisionTracking { sdk in
            if let expectedIdentity {
                try await Self.requireSignedInIdentity(expectedIdentity, in: sdk)
            }
            return try await sdk.uploadProfileAvatar(bytes: bytes, contentType: contentType)
        }
        return record.uri
    }

    func deletePaykitProfile() async throws {
        try await withStateRevisionTracking { sdk in
            guard let publicKey = try await sdk.identityStatus()?.publicKey else { throw PubkyServiceError.sessionNotActive }
            guard let current = try await sdk.fetchPaykitProfile(publicKey: publicKey) else { return }
            try await sdk.deletePaykitProfile(expectedRevision: current.revision)
        }
    }

    func fetchPubkyFollows(publicKey: String) async throws -> [String] {
        try await withPublicRead { try await $0.fetchPubkyFollows(publicKey: publicKey, maxEntries: 10000) }
    }

    func contactRecords() async throws -> [Paykit.ContactRecord] {
        try await withSdk { sdk in
            try await sdk.contactRecords()
        }
    }

    func contactRecord(publicKey: String) async throws -> Paykit.ContactRecord? {
        try await withSdk { sdk in
            try await sdk.contactRecord(publicKey: publicKey)
        }
    }

    /// With `expectedIdentity`, it saves only while that identity is signed in, checked in the same locked operation as the
    /// save, so a save that a sign-out or another identity's sign-in overtakes writes nothing and throws `identityChanged`.
    func saveContact(
        publicKey: String,
        label: String?,
        restorePrivateConnection: Bool = false,
        expectedIdentity: String? = nil
    ) async throws -> Paykit.ContactRecord {
        try await withStateRevisionTracking { sdk in
            if let expectedIdentity {
                try await Self.requireSignedInIdentity(expectedIdentity, in: sdk)
            }
            let update = Paykit.ContactUpdate(publicKey: publicKey, label: label)
            if restorePrivateConnection {
                let saved = try await sdk.saveContactsAndUnblockPeers(updates: [update])
                return saved[0]
            }
            guard try await sdk.contactRecord(publicKey: publicKey) != nil else { throw PubkyServiceError.profileNotFound }
            return try await sdk.saveContact(update: update)
        }
    }

    func saveContacts(updates: [Paykit.ContactUpdate], expectedIdentity: String? = nil) async throws -> [Paykit.ContactRecord] {
        guard !updates.isEmpty else { return [] }
        return try await withStateRevisionTracking { sdk in
            if let expectedIdentity {
                try await Self.requireSignedInIdentity(expectedIdentity, in: sdk)
            }
            return try await sdk.saveContactsAndUnblockPeers(updates: updates)
        }
    }

    func removeContact(publicKey: String) async throws -> Paykit.ContactRecord? {
        try await withStateRevisionTracking { sdk in
            let peers = try await sdk.linkedPeers().filter { PubkyPublicKeyFormat.matches($0.counterparty, publicKey) }
            let now = Date()
            let activeSubscriptions = try await sdk.paymentRequests().filter {
                PubkyPublicKeyFormat.matches($0.counterparty, publicKey) &&
                    $0.state == .activeRecurring &&
                    ($0.terms?.recurrence?.endsAt.flatMap(PaykitPaymentRequest.parseDate).map { $0 > now } ?? true)
            }
            guard activeSubscriptions.isEmpty else {
                let endDates = activeSubscriptions.compactMap {
                    $0.terms?.recurrence?.endsAt.flatMap(PaykitPaymentRequest.parseDate)
                }
                let latestEndDate = endDates.count == activeSubscriptions.count ? endDates.max() : nil
                throw PubkyServiceError.activeSubscription(endsAt: latestEndDate)
            }
            if peers.contains(where: { $0.state == .linked }) {
                do {
                    let report = try await sdk.clearPrivatePaymentListAndProcessOutbound(
                        counterparty: publicKey
                    )
                    if !report.failedToQueue.isEmpty || !report.failedToDeliver.isEmpty {
                        Logger.warn("Failed to withdraw private endpoints before contact deletion", context: "PaykitSdkService")
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    invalidatePaykitKeyIfNeeded(after: error)
                    Logger.warn("Failed to withdraw private endpoints before contact deletion: \(error)", context: "PaykitSdkService")
                }
            }
            _ = try await sdk.blockPeer(counterparty: publicKey)
            return try await sdk.removeContact(publicKey: publicKey)
        }
    }

    func removeContacts(publicKeys: [String]) async throws -> [Paykit.ContactRecord] {
        guard !publicKeys.isEmpty else { return [] }
        return try await withStateRevisionTracking { sdk in
            let now = Date()
            let subscribedKeys = try await Set(sdk.paymentRequests().filter {
                $0.state == .activeRecurring &&
                    ($0.terms?.recurrence?.endsAt.flatMap(PaykitPaymentRequest.parseDate).map { $0 > now } ?? true)
            }.compactMap { PubkyPublicKeyFormat.normalized($0.counterparty) })
            let removableKeys = publicKeys.filter {
                PubkyPublicKeyFormat.normalized($0).map { !subscribedKeys.contains($0) } == true
            }
            guard !removableKeys.isEmpty else { return [] }
            return try await sdk.removeContactsAndBlockPeers(publicKeys: removableKeys)
        }
    }

    func resolveContactProfile(
        publicKey: String,
        allowPubkyProfileFallback: Bool,
        priority: PaykitPublicReadPriority = .interactive
    ) async throws -> Paykit.ProfileResolution? {
        try await withPublicRead(priority: priority) {
            try await $0.resolveProfile(
                publicKey: publicKey,
                allowPubkyProfileFallback: allowPubkyProfileFallback
            )
        }
    }

    func canReceivePaymentRequests(publicKey: String, priority: PaykitPublicReadPriority = .interactive) async throws -> Bool {
        // The public registry read does not touch the session or shared state.
        try await withPublicRead(priority: priority) { sdk in
            try await sdk.paykitAppRegistry(publicKey: publicKey)?.apps.contains {
                $0.capabilities.paymentRequests && $0.capabilities.outgoingPayments
            } == true
        }
    }

    func syncPaykitApp(privatePaymentsEnabled: Bool, priority: PaykitSdkOperationLock.Priority = .ordered) async throws {
        try await withStateRevisionTracking(priority: priority) { sdk in
            var capabilities = try await appCapabilities(for: sdk.identityStatus())
            capabilities.privatePayments = capabilities.privatePayments && privatePaymentsEnabled
            _ = try await sdk.publishPaykitApp(displayName: "Bitkit", capabilities: capabilities)
        }
    }

    func syncPublicEndpoints(_ endpoints: [PublicPaykitService.Endpoint]) async throws -> EndpointSyncReport {
        try await withStateRevisionTracking(priority: endpoints.isEmpty ? .ordered : .background) { sdk in
            try await sdk.syncPublicEndpointsWithReceivingDetails(receivingDetails: endpoints.map(\.paykitPublicReceivingDetail))
        }
    }

    func syncPrivatePaymentListsWithReservations(
        _ updates: [PrivatePaymentListReservationUpdateInput],
        clearUnlistedLinkedPeers: Bool
    ) async throws -> PrivatePaymentListDeliveryReport {
        let withdraws = clearUnlistedLinkedPeers || updates.contains { $0.reservations.isEmpty }
        return try await withStateRevisionTracking(priority: withdraws ? .ordered : .background) { sdk in
            try await sdk.syncPrivatePaymentListsWithReservationsAndProcessOutbound(
                updates: updates,
                clearUnlistedLinkedPeers: clearUnlistedLinkedPeers
            )
        }
    }

    func ensureLinkWithPeer(
        _ counterparty: String,
        maxAdvanceSteps: UInt32 = 1
    ) async throws -> LinkedPeerHandshakeReport {
        try await withStateRevisionTracking { sdk in
            try await sdk.ensureLinkWithPeer(counterparty: counterparty, maxAdvanceSteps: maxAdvanceSteps)
        }
    }

    func clearPrivatePaymentLists(
        to counterparties: [String]
    ) async throws -> PrivatePaymentListDeliveryReport? {
        guard !counterparties.isEmpty else { return nil }
        return try await withStateRevisionTracking { sdk in
            let peers = try await sdk.linkedPeers()
            let blockedPeers = peers.filter { $0.state == .blocked }
            let updates = counterparties.filter { counterparty in
                !blockedPeers.contains { PubkyPublicKeyFormat.matches($0.counterparty, counterparty) }
            }.map { PrivatePaymentListReservationUpdateInput(counterparty: $0, reservations: []) }
            guard !updates.isEmpty else { return nil }
            if let publicKey = try await sdk.identityStatus()?.publicKey,
               let app = try await sdk.paykitAppRegistry(publicKey: publicKey)?.apps.first(where: { $0.appId == "bitkit" }),
               !app.capabilities.privatePayments
            {
                return nil
            }
            for update in updates where peers.contains(where: {
                $0.state == .recoveryRequired && PubkyPublicKeyFormat.matches($0.counterparty, update.counterparty)
            }) {
                do {
                    _ = try await sdk.ensureLinkWithPeer(counterparty: update.counterparty, maxAdvanceSteps: 1)
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    Logger.warn(
                        "Failed to recover private Paykit link before withdrawal: \(PaykitResolutionFailureDiagnostics.reason(for: error))",
                        context: "PaykitSdkService"
                    )
                }
            }
            return try await sdk.syncPrivatePaymentListsWithReservationsAndProcessOutbound(
                updates: updates,
                clearUnlistedLinkedPeers: false
            )
        }
    }

    @discardableResult
    func receivePrivateMessagesFromLinkedPeers() async throws -> [PrivateStreamCounterpartyIntakeReport] {
        try await receivePrivateMessagesFromLinkedPeers(priority: .ordered)
    }

    func receivePrivateMessagesFromLinkedPeers(priority: PaykitSdkOperationLock.Priority) async throws -> [PrivateStreamCounterpartyIntakeReport] {
        try await withStateRevisionTracking(priority: priority) { sdk in
            try await sdk.receivePrivateMessagesFromLinkedPeers()
        }
    }

    @discardableResult
    func receivePrivateMessages(counterparty: String) async throws -> PrivateStreamIntakeReport {
        try await withStateRevisionTracking { sdk in
            try await sdk.receivePrivateMessages(counterparty: counterparty)
        }
    }

    @discardableResult
    func processOutboundPrivateMessages(counterparty: String) async throws -> OutboundPrivateSendReport {
        try await processOutboundPrivateMessages(counterparty: counterparty, priority: .ordered)
    }

    func processOutboundPrivateMessages(
        counterparty: String,
        priority: PaykitSdkOperationLock.Priority
    ) async throws -> OutboundPrivateSendReport {
        try await withStateRevisionTracking(priority: priority) { sdk in
            try await sdk.processOutboundPrivateMessages(counterparty: counterparty)
        }
    }

    @discardableResult
    func processPendingPrivateMessages() async throws -> [OutboundPrivateCounterpartySendReport] {
        try await processPendingPrivateMessages(priority: .ordered)
    }

    func processPendingPrivateMessages(priority: PaykitSdkOperationLock.Priority) async throws -> [OutboundPrivateCounterpartySendReport] {
        try await withStateRevisionTracking(priority: priority) { sdk in
            try await sdk.processPendingPrivateMessages()
        }
    }

    func paymentRequests() async throws -> [Paykit.PaymentRequestRecord] {
        try await sharedPaymentRequests().filter(Self.isBitkitPaymentRequest)
    }

    func sharedPaymentRequests() async throws -> [Paykit.PaymentRequestRecord] {
        try await sharedPaymentRequests(priority: .ordered)
    }

    func sharedPaymentRequests(priority: PaykitSdkOperationLock.Priority) async throws -> [Paykit.PaymentRequestRecord] {
        try await withSdk(priority: priority) { sdk in
            try await sdk.paymentRequests()
        }
    }

    func sharedPaymentRequests(expectedIdentity: String) async throws -> [Paykit.PaymentRequestRecord] {
        try await withSdk(priority: .interactive) { sdk in
            try await Self.requireSignedInIdentity(expectedIdentity, in: sdk)
            return try await sdk.paymentRequests()
        }
    }

    nonisolated static func isBitkitPaymentRequest(_ record: Paykit.PaymentRequestRecord) -> Bool {
        switch record.localRole {
        case .payee:
            return record.proposalAppId == "bitkit"
        case .payer:
            if let appId = record.executionClaimAppId {
                return appId == "bitkit"
            }
            // Acceptance history does not retain execution ownership after a claim is released.
            if record.state == .activeRecurring || (record.state == .accepted && record.paymentProofs.isEmpty) {
                return true
            }
            return record.payerAppId == nil || record.payerAppId == "bitkit"
        case .none, .unknown:
            return false
        }
    }

    func submitPaymentProof(
        counterparty: String,
        paymentRequestId: String,
        proof: Paykit.PaymentProofSubmission
    ) async throws -> Paykit.PaymentRequestRecord {
        try await withStateRevisionTracking { sdk in
            try await sdk.submitPaymentProof(
                counterparty: counterparty,
                paymentRequestId: paymentRequestId,
                proof: proof
            )
        }
    }

    func proposePaymentRequest(
        counterparty: String,
        terms: Paykit.PaymentRequestTerms,
        expectedIdentity: String
    ) async throws -> Paykit.PaymentRequestRecord {
        try await withStateRevisionTracking(priority: .interactive) { sdk in
            guard let identityStatus = try await sdk.identityStatus(),
                  identityStatus.capability == .privateLinkCapable,
                  PubkyPublicKeyFormat.matches(identityStatus.publicKey, expectedIdentity)
            else {
                throw PaykitPaymentRequestError.requestUnavailable
            }
            return try await sdk.proposePaymentRequest(
                counterparty: counterparty,
                terms: terms
            )
        }
    }

    func acceptPaymentRequest(
        counterparty: String,
        paymentRequestId: String
    ) async throws -> Paykit.PaymentRequestRecord {
        try await withStateRevisionTracking { sdk in
            _ = try await sdk.claimPaymentRequestForExecution(counterparty: counterparty, paymentRequestId: paymentRequestId)
            return try await sdk.acceptPaymentRequest(
                counterparty: counterparty,
                paymentRequestId: paymentRequestId
            )
        }
    }

    func claimPaymentRequestForExecution(counterparty: String, paymentRequestId: String) async throws -> Paykit.PaymentRequestRecord {
        try await withStateRevisionTracking { sdk in
            try await sdk.claimPaymentRequestForExecution(counterparty: counterparty, paymentRequestId: paymentRequestId)
        }
    }

    func rejectPaymentRequest(
        counterparty: String,
        paymentRequestId: String,
        reason: String? = nil
    ) async throws -> Paykit.PaymentRequestRecord {
        try await withStateRevisionTracking { sdk in
            try await sdk.rejectPaymentRequest(
                counterparty: counterparty,
                paymentRequestId: paymentRequestId,
                reason: reason
            )
        }
    }

    func cancelPaymentRequest(
        counterparty: String,
        paymentRequestId: String,
        reason: String? = nil
    ) async throws -> Paykit.PaymentRequestRecord {
        try await withStateRevisionTracking { sdk in
            try await sdk.cancelPaymentRequest(
                counterparty: counterparty,
                paymentRequestId: paymentRequestId,
                reason: reason
            )
        }
    }

    func linkedPeers() async throws -> [LinkedPeerRecord] {
        try await linkedPeers(priority: .ordered)
    }

    func linkedPeers(priority: PaykitSdkOperationLock.Priority) async throws -> [LinkedPeerRecord] {
        try await withSdk(priority: priority) { sdk in
            try await sdk.linkedPeers()
        }
    }

    func pendingOutboundPrivateCounterparties(priority: PaykitSdkOperationLock.Priority = .ordered) async throws -> [String] {
        try await withSdk(priority: priority) { sdk in
            try await sdk.pendingOutboundPrivateCounterparties()
        }
    }

    func prepareAndResolvePrivateContactPayment(
        counterparty: String,
        amount: PaymentAmountContext? = nil,
        afterPrivatePaymentListVersion: UInt64?
    ) async throws -> PreparedPrivateContactPayment {
        try await withStateRevisionTracking(priority: .interactive) { sdk in
            try await sdk.prepareAndResolvePrivateContactPayment(
                counterparty: counterparty,
                amount: amount,
                afterPrivatePaymentListVersion: afterPrivatePaymentListVersion,
                maxAdvanceSteps: 1
            )
        }
    }

    func prepareAndResolvePrivatePaymentRequest(
        counterparty: String,
        paymentRequestId: String,
        afterPrivatePaymentListVersion: UInt64?
    ) async throws -> PreparedPrivateContactPayment {
        try await withStateRevisionTracking(priority: .interactive) { sdk in
            try await sdk.prepareAndResolvePrivatePaymentRequest(
                counterparty: counterparty,
                paymentRequestId: paymentRequestId,
                afterPrivatePaymentListVersion: afterPrivatePaymentListVersion,
                maxAdvanceSteps: 1
            )
        }
    }

    func resolvePublicContactPayment(counterparty: String) async throws -> PublicContactPaymentResolution {
        try await withPublicRead { sdk in
            let result = try await sdk.resolvePublicContactPayment(counterparty: counterparty, amount: nil)
            guard self.sdk === sdk else { throw PubkyServiceError.identityChanged }
            return result
        }
    }

    func exportBackupState() async throws -> String {
        try await withSdk { sdk in
            try await sdk.exportBackupString()
        }
    }

    func signOut() async throws {
        try await withStateRevisionTracking { sdk in
            _ = try await sdk.signOut()
        }
        resetRuntime()
    }

    func forgetSessionAccess() async throws {
        try await operationLock.withLock {
            defer { resetRuntime() }
            _ = try await handle().forgetSessionAccess()
            markWalletBackupDataChanged()
        }
    }

    func withWalletWipe<T>(_ operation: () async throws -> T) async throws -> T {
        try await operationLock.withWalletWipe {
            resetRuntime()
            defer {
                sessionProvider.clearLiveSessionAccess()
                resetRuntime()
            }
            return try await operation()
        }
    }

    func clearState() async {
        do {
            try await operationLock.withLock {
                resetRuntime()
                markWalletBackupDataChanged()
            }
        } catch {
            Logger.warn("Skipped Paykit state cleanup during wallet wipe", context: "PaykitSdkService")
        }
    }

    nonisolated static func localSecretKey(fromHex secretKeyHex: String) throws -> PubkyLocalSecretKey {
        let hex = secretKeyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count.isMultiple(of: 2) else {
            throw PaykitError.Identity(code: "invalid_secret_key", context: "Secret key hex has odd length")
        }
        let bytes = hex.hexaData
        guard bytes.count == hex.count / 2 else {
            throw PaykitError.Identity(code: "invalid_secret_key", context: "Secret key hex is invalid")
        }
        return PubkyLocalSecretKey(bytes: bytes)
    }

    nonisolated static func secretKeyHex(from secretKey: PubkyLocalSecretKey) -> String {
        secretKey.exportBytes().hex
    }

    nonisolated static func requiredCapabilities() throws -> String {
        Paykit.paykitAuthorizerSessionCapabilities()
    }

    private func handle() throws -> PaykitSdk {
        if let sdk {
            return sdk
        }

        let created = try sdkFactory?() ?? PaykitSdk.withPaymentAdapterAndPubkySharedStateAndClientConfig(
            sessionProvider: sessionProvider,
            paymentAdapter: paymentAdapter,
            config: Self.config(),
            pubkyClient: pubkyClientConfig
        )
        sdk = created
        return created
    }

    private func withPublicRead<T>(
        priority: PaykitPublicReadPriority = .interactive,
        _ read: (PaykitSdk) async throws -> T
    ) async throws -> T {
        try await operationLock.withoutLock {
            let instance: PaykitSdk = if let sdk {
                sdk
            } else {
                try await operationLock.withCancellableLock { try handle() }
            }
            return try await publicReadSlots.withSlot(priority) { try await read(instance) }
        }
    }

    private func withSdk<T>(
        priority: PaykitSdkOperationLock.Priority = .ordered,
        _ operation: (PaykitSdk) async throws -> T
    ) async throws -> T {
        try await operationLock.withLock(priority: priority) {
            try await withSdkErrorHandling {
                try await refreshPaykitKey()
                return try await operation(handle())
            }
        }
    }

    private func withSdkErrorHandling<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            invalidatePaykitKeyIfNeeded(after: error)
            throw error
        }
    }

    private func invalidatePaykitKeyIfNeeded(after error: Error) {
        guard case PaykitError.Identity = error else { return }
        // Refresh on the next authenticated operation; never replay a possibly completed write or lower the generation floor.
        cachedPaykitKey = nil
        cachedBackupState = nil
    }

    private func withStateRevisionTracking<T>(
        priority: PaykitSdkOperationLock.Priority = .ordered,
        _ operation: (PaykitSdk) async throws -> T
    ) async throws -> T {
        try await withSdk(priority: priority) { sdk in
            return try await Self.withBackupStateRevisionTracking(
                readRevision: { try await self.withSdkErrorHandling { try await sdk.backupStateRevision() } },
                readStateRevision: { try sdk.stateRevision() },
                readObservedSnapshot: {
                    try sdk.observedBackupStateRevision().map {
                        BackupStateSnapshot(stateRevision: $0.stateRevision, backupRevision: $0.backupRevision)
                    }
                },
                cachedSnapshot: self.cachedBackupState,
                onSnapshot: { self.cachedBackupState = $0 },
                onChange: { self.markWalletBackupDataChanged() },
                operation: { try await operation(sdk) }
            )
        }
    }

    static func withBackupStateRevisionTracking<T>(
        readRevision: () async throws -> String,
        readStateRevision: () throws -> String? = { nil },
        readObservedSnapshot: () throws -> BackupStateSnapshot? = { nil },
        cachedSnapshot: BackupStateSnapshot? = nil,
        onSnapshot: (BackupStateSnapshot?) -> Void = { _ in },
        onChange: () async -> Void,
        operation: () async throws -> T
    ) async throws -> T {
        // An intervening SDK read must not replace the last backup comparison baseline.
        let previousRevision: String? = if let cachedSnapshot {
            cachedSnapshot.backupRevision
        } else {
            try? await readRevision()
        }
        let result: T
        do {
            result = try await operation()
        } catch {
            // A failed write can change remote state without advancing the local revision.
            onSnapshot(nil)
            await onChange()
            throw error
        }
        let nextRevision: String?
        let nextSnapshot: BackupStateSnapshot?
        if Task.isCancelled {
            nextRevision = nil
            nextSnapshot = nil
        } else if let observed = try? readObservedSnapshot(),
                  observed.stateRevision == (try? readStateRevision())
        {
            nextRevision = observed.backupRevision
            nextSnapshot = observed
        } else {
            nextRevision = try? await readRevision()
            if let stateRevision = try? readStateRevision(), let nextRevision {
                nextSnapshot = BackupStateSnapshot(stateRevision: stateRevision, backupRevision: nextRevision)
            } else {
                nextSnapshot = nil
            }
        }
        onSnapshot(Task.isCancelled ? nil : nextSnapshot)
        if Task.isCancelled || previousRevision == nil || nextRevision == nil || previousRevision != nextRevision {
            await onChange()
        }
        return result
    }

    private func markWalletBackupDataChanged() {
        Self.walletBackupDataChangedSubject.send()
    }

    private func resetRuntime() {
        sdk = nil
        cachedPaykitKey = nil
        cachedBackupState = nil
    }

    private func refreshPaykitKey(force: Bool = false) async throws {
        if force {
            cachedPaykitKey = nil
            cachedBackupState = nil
        }
        guard let root = try sessionProvider.loadLocalSecretKey() else {
            if cachedPaykitKey != nil { cachedBackupState = nil }
            cachedPaykitKey = nil
            return
        }
        let publicKey = try Paykit.pubkyPublicKeyFromSecret(localSecretKey: root)
        let savedGeneration = try Keychain.load(key: .paykitKeyGeneration(publicKey: publicKey))
            .map { try JSONDecoder().decode(UInt64.self, from: $0) }
        if let cachedPaykitKey, cachedPaykitKey.publicKey == publicKey, cachedPaykitKey.generation == savedGeneration {
            return
        }
        cachedPaykitKey = nil
        cachedBackupState = nil
        let key = try await paykitKey(for: root)
        sessionProvider.setPaykitIdentitySecretKey(key)
        cachedPaykitKey = (publicKey, key.keyGeneration())
    }

    func paykitKeyForAuthorization(secretKeyHex: String) async throws -> PaykitIdentitySecretKey {
        try await operationLock.withLock {
            try await withSdkErrorHandling {
                try await paykitKey(for: Self.localSecretKey(fromHex: secretKeyHex))
            }
        }
    }

    private func paykitKey(for root: PubkyLocalSecretKey) async throws -> PaykitIdentitySecretKey {
        let publicKey = try Paykit.pubkyPublicKeyFromSecret(localSecretKey: root)
        let registry = try await handle().paykitAppRegistry(publicKey: publicKey)
        let generation = registry?.keyGeneration ?? 1
        let saved = try Keychain.load(key: .paykitKeyGeneration(publicKey: publicKey))
            .map { try JSONDecoder().decode(UInt64.self, from: $0) }
        guard generation >= (saved ?? 1) else {
            throw PaykitError.Identity(code: "stale_paykit_key_generation", context: "The Paykit App Registry has an older key generation")
        }
        if saved != generation {
            try Keychain.upsert(key: .paykitKeyGeneration(publicKey: publicKey), data: JSONEncoder().encode(generation))
        }
        return try root.derivePaykitIdentitySecretKey(keyGeneration: generation)
    }

    private func persistSessionAccess(_ access: PubkySessionAccess) throws {
        guard let sessionData = access.exportSessionSecret().data(using: .utf8) else {
            throw KeychainError.failedToSave
        }
        try Keychain.upsert(key: .paykitSession, data: sessionData)

        guard AdoptedPubkyReference.current == nil, let localSecret = access.exportLocalSecretKey() else {
            try Keychain.delete(key: .pubkySecretKey)
            return
        }

        guard let secretData = Self.secretKeyHex(from: localSecret).data(using: .utf8) else {
            throw KeychainError.failedToSave
        }
        try Keychain.upsert(key: .pubkySecretKey, data: secretData)
    }

    private func activateBootstrapResult(
        _ result: PubkySessionBootstrapResult,
        previousPublicKey: String?
    ) async throws {
        let keys: [KeychainEntryType] = [.paykitSession, .pubkySecretKey]
        let previousValues = try keys.map { try Keychain.load(key: $0) }
        let sdk: PaykitSdk
        let status: IdentityStatus
        do {
            try persistSessionAccess(result.sessionAccess)
            sessionProvider.setLiveSessionAccess(result.sessionAccess)
            resetRuntime()
            try await refreshPaykitKey()
            sdk = try handle()
            status = try await sdk.initialize()
            if result.sessionAccess.exportLocalSecretKey() != nil {
                _ = try await sdk.publishPaykitNoiseKeyAuthorization()
            }
        } catch {
            var rollbackError: Error?
            for (key, value) in zip(keys, previousValues) {
                do {
                    if let value {
                        try Keychain.upsert(key: key, data: value)
                    } else {
                        try Keychain.delete(key: key)
                    }
                } catch {
                    rollbackError = rollbackError ?? error
                }
            }
            sessionProvider.clearLiveSessionAccess()
            resetRuntime()
            throw rollbackError ?? error
        }
        await PubkyProfileManager.activateCachedIdentity(publicKey: result.publicKey, previousPublicKey: previousPublicKey)
        if AdoptedPubkyReference.current != nil || result.sessionAccess.exportLocalSecretKey() == nil {
            SharedPubkyKeychain.removeAllOwn()
        }
        await publishAppIfLiveSessionAvailable(using: sdk, status: status)
        startIdentityRepublish(publicKey: result.publicKey)
    }

    private func publishAppIfLiveSessionAvailable(using sdk: PaykitSdk, status: IdentityStatus) async {
        do {
            var capabilities = appCapabilities(for: status)
            guard capabilities.privatePayments else { return }
            capabilities.privatePayments = UserDefaults.standard.bool(forKey: PrivatePaykitService.publishingEnabledKey)
            _ = try await sdk.publishPaykitApp(displayName: "Bitkit", capabilities: capabilities)
        } catch {
            invalidatePaykitKeyIfNeeded(after: error)
            Logger.warn("Failed to publish Paykit app: \(error)", context: "PaykitSdkService")
        }
    }

    private func appCapabilities(for status: IdentityStatus?) -> Paykit.PaykitAppCapabilities {
        Paykit.PaykitAppCapabilities(
            privatePayments: status?.capability == .privateLinkCapable,
            paymentRequests: status?.capability == .privateLinkCapable,
            receipts: false,
            outgoingPayments: true
        )
    }

    private func cachedIdentityPublicKey() async throws -> String? {
        // Read cached identity metadata without restoring the grant we are about to replace.
        sessionProvider.suspendStoredSessionAccess()
        defer { sessionProvider.resumeStoredSessionAccess() }
        if sdk == nil {
            sdk = try sdkFactory?()
        }
        return try await sdk?.identityStatus()?.publicKey
    }

    /// Throws `identityChanged` unless `expectedIdentity` is the identity `sdk` is signed in as. Run it inside the locked
    /// operation it guards: sign-in and sign-out also take `operationLock`, so neither can land between this
    /// check and the guarded read or write.
    private nonisolated static func requireSignedInIdentity(_ expectedIdentity: String, in sdk: PaykitSdk) async throws {
        let signedInIdentity = try await sdk.identityStatus()?.publicKey
        guard PubkyPublicKeyFormat.matches(signedInIdentity, expectedIdentity) else {
            throw PubkyServiceError.identityChanged
        }
    }

    nonisolated static func shouldDeferStaleSession(error: Error, hasStoredSession: Bool) -> Bool {
        guard hasStoredSession,
              case let PaykitError.Identity(_, context) = error
        else {
            return false
        }

        return context == "restore Pubky grant session from platform provider"
    }

    private func bootstrap() throws -> PubkySessionBootstrap {
        if let cachedBootstrap {
            return cachedBootstrap
        }
        let bootstrap = try bootstrapFactory(Self.clientID, pubkyClientConfig)
        cachedBootstrap = bootstrap
        return bootstrap
    }

    func approvalBootstrap(authUrl: String, approvedClientID: String) throws -> PubkySessionBootstrap {
        let requestClientID = try Paykit.parsePubkyAuthUrl(authUrl: authUrl).clientId
        guard !approvedClientID.isEmpty, approvedClientID == requestClientID else {
            throw AppError(
                message: "pubky_auth__invalid_request",
                debugMessage: "Approved Pubky client ID does not match auth request"
            )
        }
        return try bootstrapFactory(requestClientID, pubkyClientConfig)
    }

    nonisolated static func makePubkyClientConfig(localTestnetHost: String?) -> PubkyClientConfig {
        var config = Paykit.defaultPubkyClientConfig()
        config.localTestnetHost = localTestnetHost
        return config
    }

    private nonisolated static func config() throws -> PaykitSdkConfig {
        var config = try Paykit.defaultConfig(appId: "bitkit")
        config.publicContactSharing = .privateOnly
        return config
    }

    nonisolated static var clientID: String {
        switch Env.network {
        case .bitcoin: "bitkit.to"
        default: "staging.bitkit.to"
        }
    }
}

final class PaykitSdkOperationLock: @unchecked Sendable {
    enum Priority {
        case ordered
        case interactive
        case background
    }

    private enum Waiter {
        case uncancellable(Priority, CheckedContinuation<Void, Never>)
        case cancellable(UUID, Priority, CheckedContinuation<Void, Error>)

        var priority: Priority {
            switch self {
            case let .uncancellable(priority, _), let .cancellable(_, priority, _): priority
            }
        }
    }

    private let maxInteractiveBypasses = 3
    private let lock = NSLock()
    private var isLocked = false
    private var waiters: [Waiter] = []
    private var interactiveBypasses = 0
    private var generation = 0
    private var isWiping = false
    private var activeWipeID: UUID?
    @TaskLocal private static var walletWipeOwner: UUID?

    func withLock<T>(
        priority: Priority = .ordered,
        generation expectedGeneration: Int? = nil,
        _ operation: () async throws -> T
    ) async throws -> T {
        if ownsWipe() { return try await operation() }
        let admittedGeneration = try admit()
        await acquire(priority: priority)
        defer { release() }
        try validate(expectedGeneration ?? admittedGeneration)
        try Task.checkCancellation()
        return try await operation()
    }

    func walletGeneration() throws -> Int {
        try admit()
    }

    /// Runs `operation` without the lock but under the wallet wipe admission of `withLock`: it is rejected while a wipe
    /// is in progress. A wipe cannot drain work that does not hold the lock, so a result that a wipe overtakes is
    /// discarded and the caller gets the wipe error instead.
    func withoutLock<T>(_ operation: () async throws -> T) async throws -> T {
        if ownsWipe() { return try await operation() }
        let admittedGeneration = try admit()
        try Task.checkCancellation()
        let result = try await operation()
        try validate(admittedGeneration)
        try Task.checkCancellation()
        return result
    }

    func withWalletWipe<T>(_ operation: () async throws -> T) async throws -> T {
        let wipeID = try beginWipe()
        defer { endWipe() }
        await acquire(priority: .ordered)
        defer { release() }
        try Task.checkCancellation()
        return try await Self.$walletWipeOwner.withValue(wipeID) {
            try await operation()
        }
    }

    private func ownsWipe() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isWiping && activeWipeID != nil && Self.walletWipeOwner == activeWipeID
    }

    private func admit() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard !isWiping else { throw wipeError() }
        return generation
    }

    private func validate(_ admittedGeneration: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isWiping, generation == admittedGeneration else { throw wipeError() }
    }

    private func beginWipe() throws -> UUID {
        lock.lock()
        defer { lock.unlock() }
        guard !isWiping else { throw wipeError() }
        isWiping = true
        generation += 1
        let wipeID = UUID()
        activeWipeID = wipeID
        return wipeID
    }

    private func endWipe() {
        lock.lock()
        isWiping = false
        activeWipeID = nil
        lock.unlock()
    }

    private func wipeError() -> PaykitError {
        .Storage(code: "wallet_wipe_in_progress", context: "Paykit operation interrupted by wallet wipe")
    }

    /// Leaves the queue as soon as the caller is cancelled and never runs `operation` for a cancelled caller,
    /// so an abandoned read cannot take the lock ahead of work queued after it.
    func withCancellableLock<T>(_ operation: () async throws -> T) async throws -> T {
        if ownsWipe() { return try await operation() }
        let admittedGeneration = try admit()
        try await acquireCancellable()
        defer { release() }
        try validate(admittedGeneration)
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(priority: Priority) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isLocked {
                waiters.append(.uncancellable(priority, continuation))
                lock.unlock()
            } else {
                isLocked = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    private func acquireCancellable() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if isLocked {
                    waiters.append(.cancellable(id, .ordered, continuation))
                    lock.unlock()
                } else {
                    isLocked = true
                    lock.unlock()
                    continuation.resume()
                }
            }
        } onCancel: {
            removeWaiter(id: id)?.resume(throwing: CancellationError())
        }
    }

    private func removeWaiter(id: UUID) -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = waiters.firstIndex(where: {
            if case let .cancellable(waiterID, _, _) = $0 { return waiterID == id }
            return false
        }),
            case let .cancellable(_, _, continuation) = waiters.remove(at: index)
        else { return nil }
        return continuation
    }

    private func release() {
        let nextWaiter: Waiter?
        lock.lock()
        if waiters.isEmpty {
            isLocked = false
            interactiveBypasses = 0
            nextWaiter = nil
        } else {
            // Ordered work is a barrier: priority must not cross identity changes, cleanup, or other mutations.
            let interactiveIndex = waiters.prefix { $0.priority != .ordered }.firstIndex { $0.priority == .interactive }
            let index = interactiveBypasses < maxInteractiveBypasses ? (interactiveIndex ?? waiters.startIndex) : waiters.startIndex
            interactiveBypasses = index == waiters.startIndex ? 0 : interactiveBypasses + 1
            nextWaiter = waiters.remove(at: index)
        }
        lock.unlock()
        switch nextWaiter {
        case let .uncancellable(_, continuation):
            continuation.resume()
        case let .cancellable(_, _, continuation):
            continuation.resume()
        case nil:
            break
        }
    }

    #if DEBUG
        var waiterCountForTesting: Int {
            lock.lock()
            defer { lock.unlock() }
            return waiters.count
        }
    #endif
}

/// Caps concurrent operations. A freed slot goes to the oldest interactive waiter, or to the oldest bulk waiter when no
/// interactive one is queued, so bulk work already waiting never delays an interactive read that arrives after it.
/// Waiters leave the queue as soon as their task is cancelled, without taking a slot, so an abandoned read never runs
/// ahead of work queued after it.
final class PaykitSdkReadLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let maxConcurrent: Int
    private var inFlight = 0
    private var waiters: [(id: UUID, priority: PaykitPublicReadPriority, continuation: CheckedContinuation<Void, Error>)] = []

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    func withSlot<T>(priority: PaykitPublicReadPriority = .interactive, _ operation: () async throws -> T) async throws -> T {
        try await acquire(priority: priority)
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(priority: PaykitPublicReadPriority) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if inFlight < maxConcurrent {
                    inFlight += 1
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append((id, priority, continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            removeWaiter(id: id)?.resume(throwing: CancellationError())
        }
    }

    private func removeWaiter(id: UUID) -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
        return waiters.remove(at: index).continuation
    }

    /// Hands the slot straight to the next waiter instead of freeing it, so a newcomer cannot take it first.
    private func release() {
        lock.lock()
        guard !waiters.isEmpty else {
            inFlight -= 1
            lock.unlock()
            return
        }
        let index = waiters.firstIndex { $0.priority == .interactive } ?? waiters.startIndex
        let next = waiters.remove(at: index)
        lock.unlock()
        next.continuation.resume()
    }

    #if DEBUG
        var waiterCountForTesting: Int {
            lock.lock()
            defer { lock.unlock() }
            return waiters.count
        }
    #endif
}

/// Slots for the public read lane. Every read holds one of `readCap` read slots while it runs. A bulk read first takes
/// one of `bulkCap` bulk slots, so bulk work holds at most `bulkCap` read slots and the rest stay free for interactive
/// reads. A freed read slot goes to a queued interactive read before any bulk read queued for one, so bulk reads wait
/// while interactive reads keep every read slot busy. A bulk read takes its bulk slot before its read slot and never
/// waits for a bulk slot while holding a read slot, so the two limiters cannot deadlock. Each limiter keeps arrival
/// order within a priority and leaves the queue on cancellation.
final class PaykitPublicReadSlots: Sendable {
    private let readSlots: PaykitSdkReadLimiter
    private let bulkSlots: PaykitSdkReadLimiter

    init(readCap: Int = 6, bulkCap: Int = 4) {
        readSlots = PaykitSdkReadLimiter(maxConcurrent: readCap)
        bulkSlots = PaykitSdkReadLimiter(maxConcurrent: bulkCap)
    }

    func withSlot<T>(_ priority: PaykitPublicReadPriority, _ operation: () async throws -> T) async throws -> T {
        switch priority {
        case .interactive:
            return try await readSlots.withSlot(operation)
        case .bulk:
            return try await bulkSlots.withSlot {
                try await readSlots.withSlot(priority: .bulk, operation)
            }
        }
    }

    #if DEBUG
        var readWaiterCountForTesting: Int {
            readSlots.waiterCountForTesting
        }
    #endif
}

extension PublicPaykitService.Endpoint {
    var paykitPublicReceivingDetail: PublicReceivingDetail {
        PublicReceivingDetail(
            identifier: methodId.rawValue,
            payload: PaymentPayload(text: rawPayload)
        )
    }
}

final class PaykitSdkSessionProvider: SdkPubkySessionProvider, @unchecked Sendable {
    private let lock = NSLock()
    private let loadSessionSecret: () throws -> String?
    private let deleteKeychainValue: (KeychainEntryType) throws -> Void
    private var liveSessionAccess: PubkySessionAccess?
    private var paykitIdentitySecretKey: PaykitIdentitySecretKey?
    private var isStoredSessionAccessSuspended = false

    init(
        loadSessionSecret: @escaping () throws -> String? = { try Keychain.loadString(key: .paykitSession) },
        deleteKeychainValue: @escaping (KeychainEntryType) throws -> Void = { try Keychain.delete(key: $0) }
    ) {
        self.loadSessionSecret = loadSessionSecret
        self.deleteKeychainValue = deleteKeychainValue
    }

    func setLiveSessionAccess(_ access: PubkySessionAccess) {
        lock.lock()
        liveSessionAccess = access
        paykitIdentitySecretKey = access.exportPaykitIdentitySecretKey()
        lock.unlock()
    }

    func clearLiveSessionAccess() {
        lock.lock()
        liveSessionAccess = nil
        paykitIdentitySecretKey = nil
        lock.unlock()
    }

    func loadSessionAccess() throws -> PubkySessionAccess? {
        try paykitStorageCallback(code: "session_load_failed") {
            lock.lock()
            defer { lock.unlock() }

            guard !isStoredSessionAccessSuspended else {
                return nil
            }

            guard let sessionSecret = try loadSessionSecret(), !sessionSecret.isEmpty else {
                return nil
            }

            let liveAccess = liveSessionAccess

            if liveAccess?.exportSessionSecret() == sessionSecret {
                return liveAccess
            }

            let access = try PubkySessionAccess(
                clientId: PaykitSdkService.clientID,
                sessionSecret: sessionSecret,
                localSecretKey: loadLocalSecretKey(),
                paykitIdentitySecretKey: paykitIdentitySecretKey
            )
            liveSessionAccess = access
            return access
        }
    }

    func publicStorageAvailable() throws -> Bool {
        true
    }

    func canDeferStaleSession(error: Error) throws -> Bool {
        let hasStoredSession = try loadSessionSecret()?.isEmpty == false
        return PaykitSdkService.shouldDeferStaleSession(error: error, hasStoredSession: hasStoredSession)
    }

    func suspendStoredSessionAccess() {
        lock.lock()
        liveSessionAccess = nil
        isStoredSessionAccessSuspended = true
        lock.unlock()
    }

    func resumeStoredSessionAccess() {
        lock.lock()
        isStoredSessionAccessSuspended = false
        lock.unlock()
    }

    func clearSessionAccess() throws {
        try paykitStorageCallback(code: "session_clear_failed") {
            clearLiveSessionAccess()
            try PubkySessionAccessTeardown.clear(deleteKeychainValue: deleteKeychainValue)
        }
    }

    func loadLocalSecretKey() throws -> PubkyLocalSecretKey? {
        guard let secretKeyHex = PubkyProfileManager.activeSecretKeyHex() else {
            return nil
        }

        return try PaykitSdkService.localSecretKey(fromHex: secretKeyHex)
    }

    func setPaykitIdentitySecretKey(_ key: PaykitIdentitySecretKey) {
        lock.lock()
        defer { lock.unlock() }
        if paykitIdentitySecretKey?.keyGeneration() != key.keyGeneration() {
            liveSessionAccess = nil
        }
        paykitIdentitySecretKey = key
    }
}

enum PubkySessionAccessTeardown {
    static func clear(deleteKeychainValue: (KeychainEntryType) throws -> Void) throws {
        var firstError: Error?
        for key in [KeychainEntryType.paykitSession, .pubkySecretKey] {
            do {
                try deleteKeychainValue(key)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }
}

private final class PaykitSdkPaymentAdapter: SdkPaymentAdapter, @unchecked Sendable {
    func currentPublicReceivingDetails() throws -> [PublicReceivingDetail] {
        []
    }

    func currentPrivateReceivingDetails(counterparty _: String) throws -> [PrivateReceivingDetail] {
        []
    }

    func reservePrivateReceivingDetails(
        counterparty _: String
    ) throws -> PrivateReceivingDetailReservationResponse {
        PrivateReceivingDetailReservationResponse(kind: .useCurrentReceivingDetails, reservations: [])
    }

    func cancelPrivateReceivingDetailReservation(cancellation _: PrivatePaymentEndpointReservationCancellation) throws {
        // Keeping unused reserved addresses/invoices out of reusable receive pools is safer than reusing leaked details.
    }

    func selectPublicPaymentEndpointIds(request: PublicPaymentEndpointSelectionRequest) throws -> [String] {
        let parsed = request.candidates.compactMap { candidate -> (id: String, endpoint: PublicPaykitService.Endpoint)? in
            guard let endpoint = PublicPaykitService.parseEndpoint(candidate: candidate) else {
                return nil
            }
            return (candidate.candidateId, endpoint)
        }

        return PublicPaykitService.MethodId.payablePreferenceOrder.flatMap { methodId in
            parsed.compactMap { $0.endpoint.methodId == methodId ? $0.id : nil }
        }
    }

    func buildPublicPaymentTarget(endpoint: PublicPaymentEndpointCandidate) throws -> PaymentTarget {
        PaymentTarget(payload: endpoint.payload)
    }

    func selectPrivatePaymentEndpointIds(request: PrivatePaymentEndpointSelectionRequest) throws -> [String] {
        let parsed = request.candidates.compactMap { candidate -> (id: String, endpoint: PublicPaykitService.Endpoint)? in
            guard let endpoint = PublicPaykitService.parseEndpoint(candidate: candidate) else {
                return nil
            }
            return (candidate.candidateId, endpoint)
        }

        return PublicPaykitService.MethodId.payablePreferenceOrder.flatMap { methodId in
            parsed.compactMap { $0.endpoint.methodId == methodId ? $0.id : nil }
        }
    }

    func buildPrivatePaymentTarget(endpoint: PrivatePaymentEndpointCandidate) throws -> PaymentTarget {
        PaymentTarget(payload: endpoint.payload)
    }
}

func paykitStorageCallback<T>(code: String, operation: () throws -> T) throws -> T {
    do {
        return try operation()
    } catch let error as PaykitError {
        throw error
    } catch {
        throw PaykitError.Storage(code: code, context: "Platform Paykit storage operation failed")
    }
}
