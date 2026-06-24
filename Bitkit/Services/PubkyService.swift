import BitkitCore
import Combine
import Foundation
import Paykit

enum PubkyServiceError: LocalizedError {
    case invalidAuthUrl
    case ringNotInstalled
    case sessionNotActive
    case authFailed(String)
    case profileNotFound

    var errorDescription: String? {
        switch self {
        case .invalidAuthUrl:
            return "Failed to generate auth URL"
        case .ringNotInstalled:
            return "Pubky Ring is not installed"
        case .sessionNotActive:
            return "No active Pubky session"
        case let .authFailed(reason):
            return "Authentication failed: \(reason)"
        case .profileNotFound:
            return "Profile not found"
        }
    }
}

/// Service layer wrapping BitkitCore key derivation and Paykit SDK workflows.
enum PubkyService {
    static func initialize() async throws {
        try await PaykitSdkService.shared.initialize()
    }

    // MARK: - Session Management

    /// Import a session secret into paykit and return the public key.
    static func importSession(secret: String) async throws -> String {
        let result = try await PaykitSdkService.shared.importSession(secret: secret)
        return result.publicKey
    }

    static func importExternalSession(secret: String) async throws -> String {
        let result = try await PaykitSdkService.shared.importSession(secret: secret, includeLocalSecret: false)
        return result.publicKey
    }

    static func currentPublicKey() async -> String? {
        try? await PaykitSdkService.shared.currentPublicKey()
    }

    // MARK: - Auth Flow

    /// Step 1: Generate the pubkyauth:// URL to open in Pubky Ring.
    static func startAuth() async throws -> String {
        try await PaykitSdkService.shared.startAuth()
    }

    /// Step 2: Long-poll until Ring approves. Returns the raw session secret.
    static func completeAuth() async throws -> String {
        try await PaykitSdkService.shared.completeAuth()
    }

    /// Cancel an in-progress auth relay poll started by `startAuth`.
    static func cancelAuth() async throws {
        await PaykitSdkService.shared.cancelAuth()
    }

    // MARK: - Auth Approval (Bitkit as authenticator)

    /// Parse a pubkyauth:// URL to extract details for UI display.
    static func parseAuthUrl(_ authUrl: String) throws -> Paykit.PubkyAuthDetails {
        try Paykit.parsePubkyAuthUrl(authUrl: authUrl)
    }

    /// Approve a pubkyauth:// request using the local secret key.
    static func approveAuth(authUrl: String, secretKeyHex: String) async throws {
        try await PaykitSdkService.shared.approveAuth(authUrl: authUrl, secretKeyHex: secretKeyHex)
    }

    // MARK: - Key Derivation

    /// Convert a BIP39 mnemonic to a seed.
    static func mnemonicToSeed(mnemonic: String, passphrase: String? = nil) throws -> Data {
        try BitkitCore.mnemonicToSeed(mnemonicPhrase: mnemonic, passphrase: passphrase)
    }

    /// Derive an Ed25519 secret key from a BIP39 seed. Returns hex-encoded 32-byte key.
    static func derivePubkySecretKey(seed: Data) throws -> String {
        try PaykitSdkService.secretKeyHex(from: Paykit.derivePubkySecretKey(seed: seed, runtimeLabel: PaykitSdkService.pubkyDerivationRuntimeLabel))
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

    /// Sign in with an existing secret key. Returns new session secret.
    static func signIn(secretKeyHex: String) async throws -> String {
        let result = try await PaykitSdkService.shared.signIn(secretKeyHex: secretKeyHex)
        return result.sessionAccess.exportSessionSecret()
    }

    // MARK: - File Fetching

    /// Fetch raw bytes from a `pubky://` URI via PKDNS resolution.
    static func fetchFile(uri: String) async throws -> Data {
        try await PaykitSdkService.shared.fetchFile(uri: uri)
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

    static func saveContact(publicKey: String, label: String?) async throws -> Paykit.ContactRecord {
        try await PaykitSdkService.shared.saveContact(publicKey: publicKey, label: label)
    }

    static func removeContact(publicKey: String) async throws -> Paykit.ContactRecord? {
        try await PaykitSdkService.shared.removeContact(publicKey: publicKey)
    }

    static func resolveContactProfile(publicKey: String, allowPubkyProfileFallback: Bool) async throws -> Paykit.ContactProfileResolution? {
        try await PaykitSdkService.shared.resolveContactProfile(publicKey: publicKey, allowPubkyProfileFallback: allowPubkyProfileFallback)
    }

    // MARK: - Sign Out

    static func signOut() async throws {
        try await PaykitSdkService.shared.signOut()
    }

    static func forceSignOut() async {
        await PaykitSdkService.shared.forceSignOut()
    }

    static func clearSessionAccess() async {
        await PaykitSdkService.shared.clearSessionAccess()
    }
}

// MARK: - Paykit SDK Runtime

actor PaykitSdkService {
    static let shared = PaykitSdkService()
    nonisolated static let pubkyDerivationRuntimeLabel = "bitkit"
    private static let walletBackupDataChangedSubject = PassthroughSubject<Void, Never>()

    nonisolated static var walletBackupDataChangedPublisher: AnyPublisher<Void, Never> {
        walletBackupDataChangedSubject.eraseToAnyPublisher()
    }

    private let stateStore = PaykitSdkStateBlobStore()
    private let sessionProvider = PaykitSdkSessionProvider()
    private let paymentAdapter = PaykitSdkPaymentAdapter()
    private let operationLock = PaykitSdkOperationLock()
    private var sdk: PaykitSdk?
    private var activeAuthRequest: Paykit.PubkyAuthRequest?
    private var activeAuthRequestID: UUID?

    func initialize() async throws {
        try await operationLock.withLock {
            _ = try await handle().initialize()
        }
    }

    func currentPublicKey() async throws -> String? {
        try await operationLock.withLock {
            if let status = try await handle().identityStatus(), let publicKey = status.publicKey {
                return publicKey
            }

            guard let publicKey = try await handle().initialize().identity.publicKey else {
                return nil
            }

            return publicKey
        }
    }

    func identityStatus() async throws -> IdentityStatus? {
        try await operationLock.withLock {
            try await handle().identityStatus()
        }
    }

    func importSession(secret: String, includeLocalSecret: Bool = true) async throws -> PubkySessionBootstrapResult {
        try await operationLock.withLock {
            let previousPublicKey = await currentSdkStatePublicKey()
            let localSecret = includeLocalSecret ? try sessionProvider.loadLocalSecretKey() : nil
            let result = try await bootstrap().importSession(
                sessionSecret: secret,
                localSecretKey: localSecret,
                requiredCapabilities: Self.requiredCapabilities()
            )
            try await activateBootstrapResult(result, previousPublicKey: previousPublicKey, shouldStoreLocalSecret: includeLocalSecret)
            markWalletBackupDataChanged()
            return result
        }
    }

    func signUp(secretKeyHex: String, homeserverPublicKey: String, signupCode: String?) async throws -> PubkySessionBootstrapResult {
        try await operationLock.withLock {
            let previousPublicKey = await currentSdkStatePublicKey()
            let result = try await bootstrap().signUp(
                localSecretKey: Self.localSecretKey(fromHex: secretKeyHex),
                homeserverPublicKey: homeserverPublicKey,
                signupCode: signupCode
            )
            try await activateBootstrapResult(result, previousPublicKey: previousPublicKey, shouldStoreLocalSecret: true)
            markWalletBackupDataChanged()
            return result
        }
    }

    func signIn(secretKeyHex: String) async throws -> PubkySessionBootstrapResult {
        try await operationLock.withLock {
            let previousPublicKey = await currentSdkStatePublicKey()
            let result = try await bootstrap().signIn(localSecretKey: Self.localSecretKey(fromHex: secretKeyHex))
            try await activateBootstrapResult(result, previousPublicKey: previousPublicKey, shouldStoreLocalSecret: true)
            markWalletBackupDataChanged()
            return result
        }
    }

    func startAuth() async throws -> String {
        try await operationLock.withLock {
            let request = try bootstrap().startSignInAuth(capabilities: Self.requiredCapabilities())
            let requestID = UUID()
            activeAuthRequest = request
            activeAuthRequestID = requestID
            return try await request.authorizationUrl()
        }
    }

    func completeAuth() async throws -> String {
        try await operationLock.withLock {
            guard let request = activeAuthRequest else {
                throw PubkyServiceError.invalidAuthUrl
            }
            guard let requestID = activeAuthRequestID else {
                throw PubkyServiceError.invalidAuthUrl
            }

            defer {
                if activeAuthRequestID == requestID {
                    activeAuthRequest = nil
                    activeAuthRequestID = nil
                }
            }

            let previousPublicKey = await currentSdkStatePublicKey()
            let result = try await request.complete(
                localSecretKey: nil,
                requiredCapabilities: Self.requiredCapabilities()
            )
            guard activeAuthRequestID == requestID, activeAuthRequest != nil else {
                throw CancellationError()
            }
            try await activateBootstrapResult(result, previousPublicKey: previousPublicKey, shouldStoreLocalSecret: false)
            markWalletBackupDataChanged()
            return result.sessionAccess.exportSessionSecret()
        }
    }

    func cancelAuth() {
        activeAuthRequest = nil
        activeAuthRequestID = nil
    }

    func approveAuth(authUrl: String, secretKeyHex: String) async throws {
        try await operationLock.withLock {
            try await bootstrap().approveAuth(
                authUrl: authUrl,
                expectedCapabilities: Self.requiredCapabilities(),
                localSecretKey: Self.localSecretKey(fromHex: secretKeyHex)
            )
        }
    }

    func fetchFile(uri: String) async throws -> Data {
        try await operationLock.withLock {
            guard let data = try await handle().fetchPubkyFile(uri: uri) else {
                throw PubkyServiceError.profileNotFound
            }
            return data
        }
    }

    func publishPaykitProfile(_ profile: Paykit.PaykitProfile) async throws -> Paykit.PaykitProfileRecord {
        try await withStateRevisionTracking { sdk in
            try await sdk.publishPaykitProfile(profile: profile)
        }
    }

    func uploadProfileAvatar(bytes: Data, contentType: String) async throws -> String {
        let record = try await withStateRevisionTracking { sdk in
            try await sdk.uploadProfileAvatar(bytes: bytes, contentType: contentType)
        }
        return record.uri
    }

    func deletePaykitProfile() async throws {
        try await withStateRevisionTracking { sdk in
            try await sdk.deletePaykitProfile()
        }
    }

    func fetchPubkyFollows(publicKey: String) async throws -> [String] {
        try await operationLock.withLock {
            try await handle().fetchPubkyFollows(publicKey: publicKey)
        }
    }

    func contactRecords() async throws -> [Paykit.ContactRecord] {
        try await operationLock.withLock {
            try await handle().contactRecords()
        }
    }

    func saveContact(publicKey: String, label: String?) async throws -> Paykit.ContactRecord {
        try await withStateRevisionTracking { sdk in
            try await sdk.saveContact(update: Paykit.ContactUpdate(publicKey: publicKey, label: label))
        }
    }

    func removeContact(publicKey: String) async throws -> Paykit.ContactRecord? {
        try await withStateRevisionTracking { sdk in
            try await sdk.removeContact(publicKey: publicKey)
        }
    }

    func resolveContactProfile(publicKey: String, allowPubkyProfileFallback: Bool) async throws -> Paykit.ContactProfileResolution? {
        try await operationLock.withLock {
            try await handle().resolveContactProfile(publicKey: publicKey, allowPubkyProfileFallback: allowPubkyProfileFallback)
        }
    }

    func syncPublicEndpoints(_ endpoints: [PublicPaykitService.Endpoint]) async throws -> EndpointSyncReport {
        try await withStateRevisionTracking { sdk in
            try await sdk.syncPublicEndpointsWithReceivingDetails(receivingDetails: endpoints.map(\.paykitReceivingDetail))
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

    func ensureLinkWithPeer(_ counterparty: String, maxAdvanceSteps: UInt32 = 8) async throws -> LinkedPeerHandshakeReport {
        try await withStateRevisionTracking { sdk in
            try await sdk.ensureLinkWithPeer(counterparty: counterparty, maxAdvanceSteps: maxAdvanceSteps)
        }
    }

    func clearPrivatePaymentList(to counterparty: String) async throws -> PrivatePaymentListDeliveryReport {
        try await withStateRevisionTracking { sdk in
            try await sdk.clearPrivatePaymentListAndProcessOutbound(counterparty: counterparty)
        }
    }

    func receivePrivateMessagesFromLinkedPeers() async throws {
        try await withStateRevisionTracking { sdk in
            _ = try await sdk.receivePrivateMessagesFromLinkedPeers()
        }
    }

    func processPendingPrivateMessages() async throws {
        try await withStateRevisionTracking { sdk in
            _ = try await sdk.processPendingPrivateMessages()
        }
    }

    func prepareAndResolveContactPayment(counterparty: String, includePublicEndpoints: Bool) async throws -> PreparedContactPayment {
        try await withStateRevisionTracking { sdk in
            try await sdk.prepareAndResolveContactPayment(
                counterparty: counterparty,
                amount: nil,
                includePublicEndpoints: includePublicEndpoints,
                maxAdvanceSteps: 8
            )
        }
    }

    func resolvePublicContactPayment(counterparty: String) async throws -> ContactPaymentResolution {
        try await operationLock.withLock {
            try await handle().resolvePublicContactPayment(counterparty: counterparty, amount: nil)
        }
    }

    func exportBackupState() async throws -> String {
        try await operationLock.withLock {
            try await handle().exportBackupString()
        }
    }

    func restoreBackupState(_ backup: String) async throws {
        try await withStateRevisionTracking { sdk in
            _ = try await sdk.restoreBackupString(backup: backup)
        }
        resetRuntime()
    }

    func signOut() async throws {
        try await withStateRevisionTracking { sdk in
            _ = try await sdk.signOut()
        }
        resetRuntime()
    }

    func forceSignOut() async {
        await operationLock.withLock {
            sessionProvider.clearLiveSessionAccess()
            try? Keychain.delete(key: .paykitSession)
            try? Keychain.delete(key: .pubkySecretKey)
            clearStateLocked()
        }
    }

    func clearSessionAccess() async {
        await operationLock.withLock {
            sessionProvider.clearLiveSessionAccess()
            try? Keychain.delete(key: .paykitSession)
            try? Keychain.delete(key: .pubkySecretKey)
            activeAuthRequest = nil
            activeAuthRequestID = nil
            resetRuntime()
            markWalletBackupDataChanged()
        }
    }

    func clearState() async {
        await operationLock.withLock {
            clearStateLocked()
        }
    }

    private func clearStateLocked() {
        try? Keychain.delete(key: .paykitSdkState)
        activeAuthRequest = nil
        activeAuthRequestID = nil
        resetRuntime()
        markWalletBackupDataChanged()
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
        try Paykit.requiredSessionCapabilities(config: config())
    }

    private func handle() throws -> PaykitSdk {
        if let sdk {
            return sdk
        }

        let created = try PaykitSdk.withPaymentAdapter(
            stateStore: stateStore,
            sessionProvider: sessionProvider,
            paymentAdapter: paymentAdapter,
            config: Self.config()
        )
        sdk = created
        return created
    }

    private func withStateRevisionTracking<T>(_ operation: (PaykitSdk) async throws -> T) async throws -> T {
        try await operationLock.withLock {
            let sdk = try handle()
            let previousRevision = try? sdk.stateRevision()
            do {
                let result = try await operation(sdk)
                markWalletBackupDataChangedIfNeeded(from: previousRevision, sdk: sdk)
                return result
            } catch {
                markWalletBackupDataChangedIfNeeded(from: previousRevision, sdk: sdk)
                throw error
            }
        }
    }

    private func markWalletBackupDataChangedIfNeeded(from previousRevision: String?, sdk: PaykitSdk) {
        guard let nextRevision = try? sdk.stateRevision(), previousRevision != nextRevision else {
            return
        }
        markWalletBackupDataChanged()
    }

    private func markWalletBackupDataChanged() {
        Self.walletBackupDataChangedSubject.send()
    }

    private func resetRuntime() {
        sdk = nil
    }

    private func persistSessionAccess(_ access: PubkySessionAccess, shouldStoreLocalSecret: Bool) throws {
        guard let sessionData = access.exportSessionSecret().data(using: .utf8) else {
            throw KeychainError.failedToSave
        }
        try Keychain.upsert(key: .paykitSession, data: sessionData)

        guard shouldStoreLocalSecret, let localSecret = access.exportLocalSecretKey() else {
            try? Keychain.delete(key: .pubkySecretKey)
            return
        }

        guard let secretData = Self.secretKeyHex(from: localSecret).data(using: .utf8) else {
            throw KeychainError.failedToSave
        }
        try Keychain.upsert(key: .pubkySecretKey, data: secretData)
    }

    private func activateBootstrapResult(
        _ result: PubkySessionBootstrapResult,
        previousPublicKey: String?,
        shouldStoreLocalSecret: Bool
    ) async throws {
        try persistSessionAccess(result.sessionAccess, shouldStoreLocalSecret: shouldStoreLocalSecret)
        sessionProvider.setLiveSessionAccess(result.sessionAccess)
        if !Self.publicKeysMatch(previousPublicKey, result.publicKey) {
            try? Keychain.delete(key: .paykitSdkState)
        }
        resetRuntime()
        _ = try await handle().initialize()
    }

    private func currentSdkStatePublicKey() async -> String? {
        do {
            return try await handle().identityStatus()?.publicKey
        } catch {
            try? Keychain.delete(key: .paykitSdkState)
            resetRuntime()
            return nil
        }
    }

    private nonisolated static func publicKeysMatch(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs,
              let normalizedLhs = try? Paykit.normalizePubkyPublicKey(value: lhs),
              let normalizedRhs = try? Paykit.normalizePubkyPublicKey(value: rhs)
        else {
            return false
        }
        return normalizedLhs == normalizedRhs
    }

    private func bootstrap() throws -> PubkySessionBootstrap {
        try PubkySessionBootstrap()
    }

    private nonisolated static func config() -> PaykitSdkConfig {
        var config = Paykit.defaultConfig()
        config.profileNamespace = switch Env.network {
        case .bitcoin: "bitkit.to"
        default: "staging.bitkit.to"
        }
        config.endpointManagementScope = .managedOnly
        config.encryptedLinkRecoveryMarkers = .enabled
        config.publicContactSharing = .localOnly
        return config
    }
}

private final class PaykitSdkOperationLock: @unchecked Sendable {
    private let lock = NSLock()
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isLocked {
                waiters.append(continuation)
                lock.unlock()
            } else {
                isLocked = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    private func release() {
        let nextWaiter: CheckedContinuation<Void, Never>?
        lock.lock()
        if waiters.isEmpty {
            isLocked = false
            nextWaiter = nil
        } else {
            nextWaiter = waiters.removeFirst()
        }
        lock.unlock()
        nextWaiter?.resume()
    }
}

extension PublicPaykitService.Endpoint {
    var paykitReceivingDetail: ReceivingDetail {
        ReceivingDetail(
            identifier: methodId.rawValue,
            payload: PaymentPayload(text: rawPayload)
        )
    }
}

private final class PaykitSdkStateBlobStore: SdkStateBlobStore, @unchecked Sendable {
    private let lock = NSLock()

    init() {}

    func loadStateBlob() throws -> SdkStateBlobSnapshot? {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try Keychain.load(key: .paykitSdkState) else {
            return nil
        }

        return try decodeSdkStateBlobSnapshot(bytes: data)
    }

    func saveStateBlobAtomically(blob: SdkStateBlob, expectedRevision: String?) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let currentRevision = try Keychain.load(key: .paykitSdkState)
            .map { try decodeSdkStateBlobSnapshot(bytes: $0).revision }
        guard currentRevision == expectedRevision else {
            throw PaykitError.Storage(code: "revision_conflict", context: "SDK state revision changed")
        }

        let nextRevision = UUID().uuidString
        let snapshot = SdkStateBlobSnapshot(blob: blob, revision: nextRevision)
        let encoded = try encodeSdkStateBlobSnapshot(snapshot: snapshot)
        try Keychain.upsert(key: .paykitSdkState, data: encoded)
        return nextRevision
    }
}

private final class PaykitSdkSessionProvider: SdkPubkySessionProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var liveSessionAccess: PubkySessionAccess?

    func setLiveSessionAccess(_ access: PubkySessionAccess) {
        lock.lock()
        liveSessionAccess = access
        lock.unlock()
    }

    func clearLiveSessionAccess() {
        lock.lock()
        liveSessionAccess = nil
        lock.unlock()
    }

    func loadSessionAccess() throws -> PubkySessionAccess? {
        guard let sessionSecret = try Keychain.loadString(key: .paykitSession), !sessionSecret.isEmpty else {
            return nil
        }

        lock.lock()
        let liveAccess = liveSessionAccess
        lock.unlock()

        if liveAccess?.exportSessionSecret() == sessionSecret {
            return liveAccess
        }

        return try PubkySessionAccess(
            sessionSecret: sessionSecret,
            localSecretKey: loadLocalSecretKey()
        )
    }

    func publicStorageAvailable() throws -> Bool {
        true
    }

    func clearSessionAccess() throws {
        clearLiveSessionAccess()
        try? Keychain.delete(key: .paykitSession)
        try? Keychain.delete(key: .pubkySecretKey)
    }

    func loadLocalSecretKey() throws -> PubkyLocalSecretKey? {
        guard let secretKeyHex = try Keychain.loadString(key: .pubkySecretKey), !secretKeyHex.isEmpty else {
            return nil
        }

        return try PaykitSdkService.localSecretKey(fromHex: secretKeyHex)
    }
}

private final class PaykitSdkPaymentAdapter: SdkPaymentAdapter, @unchecked Sendable {
    func currentReceivingDetails(scope: ReceivingDetailScope) throws -> [ReceivingDetail] {
        []
    }

    func reserveReceivingDetails(counterparty: String) throws -> ReceivingDetailReservationResponse {
        ReceivingDetailReservationResponse(kind: .useCurrentReceivingDetails, reservations: [])
    }

    func cancelReceivingDetailReservation(cancellation _: PaymentEndpointReservationCancellation) throws {
        // Keeping unused reserved addresses/invoices out of reusable receive pools is safer than reusing leaked details.
    }

    func selectPaymentEndpointIds(request: PaymentEndpointSelectionRequest) throws -> [String] {
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

    func buildPaymentTarget(endpoint: PaymentEndpointCandidate) throws -> PaymentTarget {
        PaymentTarget(payload: endpoint.payload)
    }
}
