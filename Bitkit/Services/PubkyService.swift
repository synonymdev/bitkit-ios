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
        }
    }
}

struct PubkyRegisteredIdentity {
    let result: PubkySessionBootstrapResult
    let walletGeneration: Int
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
        try await sdkService.republishIdentityIfNeeded(publicKey: pubkyPublicKeyFromSecret(secretKeyHex: secretKeyHex))
        try Task.checkCancellation()
        try await sdkService.approveAuth(
            authUrl: authUrl,
            expectedCapabilities: expectedCapabilities,
            approvedClientID: approvedClientID,
            secretKeyHex: secretKeyHex
        )
    }

    static func approveRingAuth(authUrl: String, secretKeyHex: String, sdkService: PaykitSdkService = .shared) async throws {
        try await sdkService.republishIdentityIfNeeded(publicKey: pubkyPublicKeyFromSecret(secretKeyHex: secretKeyHex))
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
        try await sdkService.republishIdentityIfNeeded(publicKey: pubkyPublicKeyFromSecret(secretKeyHex: secretKeyHex))
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

    static func publishPaykitProfile(_ profile: Paykit.PaykitProfile) async throws {
        _ = try await PaykitSdkService.shared.publishPaykitProfile(profile)
    }

    static func uploadProfileAvatar(bytes: Data, contentType: String) async throws -> String {
        try await PaykitSdkService.shared.uploadProfileAvatar(bytes: bytes, contentType: contentType)
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
                            restorePrivateConnection: Bool = false) async throws -> Paykit.ContactRecord
    {
        try await PaykitSdkService.shared.saveContact(
            publicKey: publicKey,
            label: label,
            restorePrivateConnection: restorePrivateConnection
        )
    }

    static func removeContact(publicKey: String) async throws -> Paykit.ContactRecord? {
        try await PaykitSdkService.shared.removeContact(publicKey: publicKey)
    }

    static func resolveContactProfile(publicKey: String, allowPubkyProfileFallback: Bool) async throws -> Paykit.ProfileResolution? {
        try await PaykitSdkService.shared.resolveContactProfile(publicKey: publicKey, allowPubkyProfileFallback: allowPubkyProfileFallback)
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

    static let shared = PaykitSdkService()
    private static let walletBackupDataChangedSubject = PassthroughSubject<Void, Never>()

    nonisolated static var walletBackupDataChangedPublisher: AnyPublisher<Void, Never> {
        walletBackupDataChangedSubject.eraseToAnyPublisher()
    }

    private let sessionProvider = PaykitSdkSessionProvider()
    private let paymentAdapter = PaykitSdkPaymentAdapter()
    private let operationLock = PaykitSdkOperationLock()
    private let pubkyClientConfig = PaykitSdkService.makePubkyClientConfig(localTestnetHost: Env.pubkyLocalTestnetHost)
    private let sdkFactory: (() throws -> PaykitSdk)?
    private let bootstrapFactory: BootstrapFactory
    private var cachedBootstrap: PubkySessionBootstrap?
    private var isRepublishingIdentity = false
    private var republishPublicKey: String?
    private var nextIdentityRepublishAt = Date.distantPast
    private var lastIdentityRepublishAt = Date.distantPast
    private var sdk: PaykitSdk?

    init(
        sdkFactory: (() throws -> PaykitSdk)? = nil,
        bootstrapFactory: @escaping BootstrapFactory = PubkySessionBootstrap.withPubkyClientConfig(clientId:pubkyClient:)
    ) {
        self.sdkFactory = sdkFactory
        self.bootstrapFactory = bootstrapFactory
    }

    func initialize() async throws {
        Task { await republishIdentityIfNeeded() }
        try await operationLock.withLock {
            try await initializeLocked()
        }
    }

    private func initializeLocked() async throws {
        try await refreshPaykitKey()
        var sdk = try handle()
        do {
            _ = try await sdk.initialize()
        } catch {
            guard try sessionProvider.canDeferStaleSession(error: error) else { throw error }

            Logger.warn("Deferring stale Paykit session restoration until SDK setup completes", context: "PaykitSdkService")
            sessionProvider.suspendStoredSessionAccess()
            resetRuntime()
            do {
                sdk = try handle()
                _ = try await sdk.initialize()
            } catch {
                sessionProvider.resumeStoredSessionAccess()
                throw error
            }
            sessionProvider.resumeStoredSessionAccess()
        }
        await publishAppIfLiveSessionAvailable(using: sdk)
    }

    /// Keep credential reads and fallback activation atomic with sign-out and identity changes.
    func restorePersistedSession() async throws -> PubkyProfileManager.SessionInitializationResult {
        Task { await republishIdentityIfNeeded() }
        return try await operationLock.withLock {
            try await initializeLocked()
            return try await PubkyProfileManager.resolveSessionInitialization(
                savedSessionSecret: Keychain.loadString(key: .paykitSession),
                storedSecretKeyHex: PubkyProfileManager.activeSecretKeyHex(),
                importSession: { try await self.importSessionLocked(secret: $0).publicKey },
                signInWithSecretKey: { try await self.signInLocked(secretKeyHex: $0).publicKey }
            )
        }
    }

    func republishIdentityIfNeeded(publicKey: String? = nil, now: Date = Date(), timeout: Duration = .seconds(5)) async {
        guard !Task.isCancelled else { return }
        // Swift FFI may ignore cancellation; keep the in-flight guard until publication actually finishes.
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let publication = Task {
            await republishIdentity(publicKey: publicKey, now: now)
            continuation.finish()
        }
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
            publication.cancel()
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
        defer { isRepublishingIdentity = false }

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
        try await withSdk { sdk in
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
        try await operationLock.withLock {
            guard let data = try await handle().fetchPubkyFileBounded(uri: uri, maxBytes: maxBytes) else {
                throw PubkyServiceError.profileNotFound
            }
            return data
        }
    }

    func publishPaykitProfile(_ profile: Paykit.PaykitProfile) async throws -> Paykit.PaykitProfileRecord {
        try await withStateRevisionTracking { sdk in
            guard let publicKey = try await sdk.identityStatus()?.publicKey else { throw PubkyServiceError.sessionNotActive }
            let current = try await sdk.fetchPaykitProfile(publicKey: publicKey)
            return try await sdk.publishPaykitProfile(profile: profile, expectedRevision: current?.revision)
        }
    }

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

    func deletePaykitProfile() async throws {
        try await withStateRevisionTracking { sdk in
            guard let publicKey = try await sdk.identityStatus()?.publicKey else { throw PubkyServiceError.sessionNotActive }
            guard let current = try await sdk.fetchPaykitProfile(publicKey: publicKey) else { return }
            try await sdk.deletePaykitProfile(expectedRevision: current.revision)
        }
    }

    func fetchPubkyFollows(publicKey: String) async throws -> [String] {
        try await operationLock.withLock {
            try await handle().fetchPubkyFollows(publicKey: publicKey, maxEntries: 10000)
        }
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

    func saveContact(
        publicKey: String,
        label: String?,
        restorePrivateConnection: Bool = false
    ) async throws -> Paykit.ContactRecord {
        try await withStateRevisionTracking { sdk in
            let existing = try await sdk.contactRecord(publicKey: publicKey)
            guard restorePrivateConnection || existing != nil else { throw PubkyServiceError.profileNotFound }
            if restorePrivateConnection {
                let blockedPeers = try await sdk.linkedPeers().filter {
                    $0.state == .blocked && PubkyPublicKeyFormat.matches($0.counterparty, publicKey)
                }
                do {
                    for peer in blockedPeers {
                        _ = try await sdk.unblockPeer(counterparty: peer.counterparty)
                    }
                    return try await sdk.saveContact(update: Paykit.ContactUpdate(publicKey: publicKey, label: label))
                } catch {
                    let restorationError = error
                    for peer in blockedPeers {
                        do {
                            _ = try await sdk.blockPeer(counterparty: peer.counterparty)
                        } catch {
                            Logger.error("Failed to restore peer block after contact save failed: \(error)", context: "PaykitSdkService")
                        }
                    }
                    throw restorationError
                }
            }
            return try await sdk.saveContact(update: Paykit.ContactUpdate(publicKey: publicKey, label: label))
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
                    Logger.warn("Failed to withdraw private endpoints before contact deletion: \(error)", context: "PaykitSdkService")
                }
            }
            _ = try await sdk.blockPeer(counterparty: publicKey)
            return try await sdk.removeContact(publicKey: publicKey)
        }
    }

    func resolveContactProfile(publicKey: String, allowPubkyProfileFallback: Bool) async throws -> Paykit.ProfileResolution? {
        try await operationLock.withLock {
            try await handle().resolveProfile(
                publicKey: publicKey,
                allowPubkyProfileFallback: allowPubkyProfileFallback
            )
        }
    }

    /// Takes the SDK lock per read and drops out of its queue once cancelled, so an abandoned eligibility check
    /// holds up a payment for at most the one read already in flight.
    func canReceivePaymentRequests(publicKey: String) async throws -> Bool {
        try Task.checkCancellation()
        return try await operationLock.withCancellableLock {
            try await handle().paykitAppRegistry(publicKey: publicKey)?.apps.contains {
                $0.capabilities.paymentRequests && $0.capabilities.outgoingPayments
            } == true
        }
    }

    func syncPaykitApp(privatePaymentsEnabled: Bool) async throws {
        try await withStateRevisionTracking { sdk in
            var capabilities = try await appCapabilities(using: sdk)
            capabilities.privatePayments = capabilities.privatePayments &&
                (privatePaymentsEnabled || UserDefaults.standard.bool(forKey: PrivatePaykitService.cleanupPendingKey))
            _ = try await sdk.publishPaykitApp(displayName: "Bitkit", capabilities: capabilities)
        }
    }

    func syncPublicEndpoints(_ endpoints: [PublicPaykitService.Endpoint]) async throws -> EndpointSyncReport {
        try await withStateRevisionTracking { sdk in
            try await sdk.syncPublicEndpointsWithReceivingDetails(receivingDetails: endpoints.map(\.paykitPublicReceivingDetail))
        }
    }

    func syncPrivatePaymentListsWithReservations(
        _ updates: [PrivatePaymentListReservationUpdateInput],
        clearUnlistedLinkedPeers: Bool
    ) async throws -> PrivatePaymentListDeliveryReport {
        return try await withStateRevisionTracking { sdk in
            try await sdk.syncPrivatePaymentListsWithReservationsAndProcessOutbound(
                updates: updates,
                clearUnlistedLinkedPeers: clearUnlistedLinkedPeers
            )
        }
    }

    func ensureLinkWithPeer(
        _ counterparty: String,
        maxAdvanceSteps: UInt32 = 8
    ) async throws -> LinkedPeerHandshakeReport {
        try await withStateRevisionTracking { sdk in
            try await sdk.ensureLinkWithPeer(counterparty: counterparty, maxAdvanceSteps: maxAdvanceSteps)
        }
    }

    func clearPrivatePaymentList(
        to counterparty: String
    ) async throws -> PrivatePaymentListDeliveryReport? {
        try await withStateRevisionTracking { sdk in
            if try await sdk.linkedPeers().contains(where: {
                $0.state == .blocked && PubkyPublicKeyFormat.matches($0.counterparty, counterparty)
            }) {
                return nil
            }
            return try await sdk.clearPrivatePaymentListAndProcessOutbound(counterparty: counterparty)
        }
    }

    @discardableResult
    func receivePrivateMessagesFromLinkedPeers() async throws -> [PrivateStreamCounterpartyIntakeReport] {
        try await withStateRevisionTracking { sdk in
            try await sdk.receivePrivateMessagesFromLinkedPeers()
        }
    }

    @discardableResult
    func processPendingPrivateMessages() async throws -> [OutboundPrivateCounterpartySendReport] {
        try await withStateRevisionTracking { sdk in
            try await sdk.processPendingPrivateMessages()
        }
    }

    func paymentRequests() async throws -> [Paykit.PaymentRequestRecord] {
        try await sharedPaymentRequests().filter(Self.isBitkitPaymentRequest)
    }

    func sharedPaymentRequests() async throws -> [Paykit.PaymentRequestRecord] {
        try await withSdk { sdk in
            try await sdk.paymentRequests()
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
        try await withStateRevisionTracking { sdk in
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
        try await withSdk { sdk in
            try await sdk.linkedPeers()
        }
    }

    func pendingOutboundPrivateCounterparties() async throws -> [String] {
        try await withSdk { sdk in
            try await sdk.pendingOutboundPrivateCounterparties()
        }
    }

    func prepareAndResolvePrivateContactPayment(
        counterparty: String,
        amount: PaymentAmountContext? = nil,
        afterPrivatePaymentListVersion: UInt64?
    ) async throws -> PreparedPrivateContactPayment {
        try await withStateRevisionTracking { sdk in
            try await sdk.prepareAndResolvePrivateContactPayment(
                counterparty: counterparty,
                amount: amount,
                afterPrivatePaymentListVersion: afterPrivatePaymentListVersion,
                maxAdvanceSteps: 8
            )
        }
    }

    func prepareAndResolvePrivatePaymentRequest(
        counterparty: String,
        paymentRequestId: String,
        afterPrivatePaymentListVersion: UInt64?
    ) async throws -> PreparedPrivateContactPayment {
        try await withStateRevisionTracking { sdk in
            try await sdk.prepareAndResolvePrivatePaymentRequest(
                counterparty: counterparty,
                paymentRequestId: paymentRequestId,
                afterPrivatePaymentListVersion: afterPrivatePaymentListVersion,
                maxAdvanceSteps: 8
            )
        }
    }

    func resolvePublicContactPayment(counterparty: String) async throws -> PublicContactPaymentResolution {
        try await operationLock.withLock {
            try await handle().resolvePublicContactPayment(counterparty: counterparty, amount: nil)
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
        Paykit.requiredSessionCapabilities()
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

    private func withSdk<T>(_ operation: (PaykitSdk) async throws -> T) async throws -> T {
        try await operationLock.withLock {
            try await refreshPaykitKey()
            let sdk = try handle()
            return try await operation(sdk)
        }
    }

    private func withStateRevisionTracking<T>(_ operation: (PaykitSdk) async throws -> T) async throws -> T {
        try await withSdk { sdk in
            return try await Self.withBackupStateRevisionTracking(
                readRevision: { try await sdk.backupStateRevision() },
                onChange: { self.markWalletBackupDataChanged() },
                operation: { try await operation(sdk) }
            )
        }
    }

    static func withBackupStateRevisionTracking<T>(
        readRevision: () async throws -> String,
        onChange: () async -> Void,
        operation: () async throws -> T
    ) async throws -> T {
        let previousRevision = try? await readRevision()
        let result: Result<T, Error>
        do {
            result = try await .success(operation())
        } catch {
            result = .failure(error)
        }
        let nextRevision = try? await readRevision()
        if previousRevision == nil || nextRevision == nil || previousRevision != nextRevision {
            await onChange()
        }
        return try result.get()
    }

    private func markWalletBackupDataChanged() {
        Self.walletBackupDataChangedSubject.send()
    }

    private func resetRuntime() {
        sdk = nil
    }

    private func refreshPaykitKey() async throws {
        guard let root = try sessionProvider.loadLocalSecretKey() else { return }
        try await sessionProvider.setPaykitIdentitySecretKey(paykitKey(for: root))
    }

    func paykitKeyForAuthorization(secretKeyHex: String) async throws -> PaykitIdentitySecretKey {
        try await operationLock.withLock {
            try await paykitKey(for: Self.localSecretKey(fromHex: secretKeyHex))
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
        do {
            try persistSessionAccess(result.sessionAccess)
            sessionProvider.setLiveSessionAccess(result.sessionAccess)
            resetRuntime()
            try await refreshPaykitKey()
            sdk = try handle()
            _ = try await sdk.initialize()
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
        await publishAppIfLiveSessionAvailable(using: sdk)
        await republishIdentityIfNeeded(publicKey: result.publicKey)
    }

    private func publishAppIfLiveSessionAvailable(using sdk: PaykitSdk) async {
        do {
            var capabilities = try await appCapabilities(using: sdk)
            guard capabilities.privatePayments else { return }
            capabilities.privatePayments = UserDefaults.standard.bool(forKey: PrivatePaykitService.publishingEnabledKey) ||
                UserDefaults.standard.bool(forKey: PrivatePaykitService.cleanupPendingKey)
            _ = try await sdk.publishPaykitApp(displayName: "Bitkit", capabilities: capabilities)
        } catch {
            Logger.warn("Failed to publish Paykit app: \(error)", context: "PaykitSdkService")
        }
    }

    private func appCapabilities(using sdk: PaykitSdk) async throws -> Paykit.PaykitAppCapabilities {
        let status = try await sdk.identityStatus()
        return Paykit.PaykitAppCapabilities(
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
        return try await handle().identityStatus()?.publicKey
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
    private enum Waiter {
        case uncancellable(CheckedContinuation<Void, Never>)
        case cancellable(UUID, CheckedContinuation<Void, Error>)
    }

    private let lock = NSLock()
    private var isLocked = false
    private var waiters: [Waiter] = []
    private var generation = 0
    private var isWiping = false
    private var activeWipeID: UUID?
    @TaskLocal private static var walletWipeOwner: UUID?

    func withLock<T>(generation expectedGeneration: Int? = nil, _ operation: () async throws -> T) async throws -> T {
        if ownsWipe() { return try await operation() }
        let admittedGeneration = try admit()
        await acquire()
        defer { release() }
        try validate(expectedGeneration ?? admittedGeneration)
        try Task.checkCancellation()
        return try await operation()
    }

    func walletGeneration() throws -> Int {
        try admit()
    }

    func withWalletWipe<T>(_ operation: () async throws -> T) async throws -> T {
        let wipeID = try beginWipe()
        defer { endWipe() }
        await acquire()
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

    private func acquire() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isLocked {
                waiters.append(.uncancellable(continuation))
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
                    waiters.append(.cancellable(id, continuation))
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
            if case let .cancellable(waiterID, _) = $0 { return waiterID == id }
            return false
        }),
            case let .cancellable(_, continuation) = waiters.remove(at: index)
        else { return nil }
        return continuation
    }

    private func release() {
        let nextWaiter: Waiter?
        lock.lock()
        if waiters.isEmpty {
            isLocked = false
            nextWaiter = nil
        } else {
            nextWaiter = waiters.removeFirst()
        }
        lock.unlock()
        switch nextWaiter {
        case let .uncancellable(continuation):
            continuation.resume()
        case let .cancellable(_, continuation):
            continuation.resume()
        case nil:
            break
        }
    }
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
