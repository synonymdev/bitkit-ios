import BitkitCore
import Combine
import Foundation
import Paykit
import VssRustClientFfi

// MARK: - BackupService

enum BackupRestoreFailurePolicy {
    static func isFatal(_ category: BackupCategory, error: Error? = nil) -> Bool {
        if category == .wallet {
            return true
        }
        var current = error
        for _ in 0 ..< 8 {
            if current is CancellationError || current is ProfileRemovalStore
                .StoreError || current is ProfileSessionRestoreLocalError || current is PubkyCredentialLocalError
            {
                return true
            }
            guard let wrapped = current as? AppError else { break }
            current = wrapped.underlyingError
        }
        return false
    }
}

struct WalletBackupRestoreGate {
    static let keychain = WalletBackupRestoreGate(
        load: { try Keychain.load(key: .paykitPendingBackupRestore) },
        store: { try Keychain.upsert(key: .paykitPendingBackupRestore, data: $0) },
        clear: { try Keychain.delete(key: .paykitPendingBackupRestore) }
    )

    private let load: () throws -> Data?
    private let store: (Data) throws -> Void
    private let clear: () throws -> Void

    init(
        load: @escaping () throws -> Data?,
        store: @escaping (Data) throws -> Void,
        clear: @escaping () throws -> Void
    ) {
        self.load = load
        self.store = store
        self.clear = clear
    }

    static func blocksWalletStart(
        isRestoreRunning: Bool,
        hasPendingRestore: Bool,
        isRestoreCompletionStart: Bool
    ) -> Bool {
        hasPendingRestore || isRestoreRunning && !isRestoreCompletionStart
    }

    func hasPendingRestore() throws -> Bool {
        try load() != nil
    }

    func performRestore(_ restore: (Data?) async throws -> Bool) async throws -> Bool {
        let retainedPayload = try beginRestore()
        let didRestorePayload = try await restore(retainedPayload)
        if didRestorePayload {
            try completeRestore()
        } else {
            try completeRestoreWithoutPayload()
        }
        return didRestorePayload
    }

    private func beginRestore() throws -> Data? {
        guard let pendingPayload = try load() else {
            try store(Data())
            return nil
        }
        return pendingPayload.isEmpty ? nil : pendingPayload
    }

    func retain(_ payload: Data) throws {
        try store(payload)
    }

    private func completeRestore() throws {
        try clear()
    }

    private func completeRestoreWithoutPayload() throws {
        guard try load()?.isEmpty == true else {
            throw incompleteRestoreError()
        }
        try clear()
    }

    func requireReplacementBackupAllowed() throws {
        guard try load() == nil else {
            throw incompleteRestoreError()
        }
    }

    private func incompleteRestoreError() -> NSError {
        NSError(domain: "BackupService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Wallet backup restore is incomplete"])
    }
}

class BackupService {
    static let shared = BackupService()

    private enum MetadataBackupError: Error {
        case deferred
        case walletBackupFailed
        case walletTemporarilyUnavailable
    }

    enum BackupOutcome {
        case completed
        case snapshotChanged
        case busy
        case temporarilyUnavailable
        case failed

        var canRetryPendingBackup: Bool {
            self == .completed || self == .snapshotChanged || self == .busy || self == .temporarilyUnavailable
        }
    }

    private let vssBackupClient = VssBackupClient.shared
    private let walletRestoreGate: WalletBackupRestoreGate
    private let walletBackupWriter = WalletBackupWriter()
    private let usdtBackupWriter = WalletBackupWriter()
    private let usdtRecoveryBackup: UsdtRecoveryBackupStore
    @MainActor weak var usdtWallet: UsdtWalletManager?
    private var backupJobs: [BackupCategory: Task<Void, Never>] = [:]
    private var runningBackupTasks: [BackupCategory: Task<BackupOutcome, Never>] = [:]
    @MainActor private var dataStoreListeners = Set<AnyCancellable>()
    @MainActor private var statusListeners = Set<AnyCancellable>()
    @MainActor private var periodicCheckTask: Task<Void, Never>?
    @MainActor private var observationTask: Task<Void, Never>?
    @MainActor private var isObserving = false
    private var schedulingGeneration: UInt64 = 0
    private var isStoppingBackups = false
    private var isRestoring = false
    private var isWiping = false
    private var backupFailureNotificationGate = BackupFailureNotificationGate()

    private let defaults: UserDefaults
    private let profileAdmission: ProfileOperationAdmission
    private let backupData: ((BackupCategory) async throws -> Data)?
    private let uploadBackup: (String, Data) async throws -> Void
    private let waitForBackupDelay: () async throws -> Void
    private let waitForTemporaryFailureDelay: (UInt64) async throws -> Void
    private let waitForForegroundRecoveryTimeout: () async throws -> Void
    private static let backupStatusesKey = "backupStatuses"
    private var backupVersions: [BackupCategory: UInt64] = [:]

    private let statusUpdateQueue = DispatchQueue(label: "backup-service-status-update", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "backup-service-state", qos: .userInitiated)
    private let backupStatusesSubject = PassthroughSubject<[BackupCategory: BackupItemStatus], Never>()

    private let backupFailureSubject = PassthroughSubject<Int, Never>()

    var backupFailurePublisher: AnyPublisher<Int, Never> {
        backupFailureSubject.eraseToAnyPublisher()
    }

    var backupStatusesPublisher: AnyPublisher<[BackupCategory: BackupItemStatus], Never> {
        backupStatusesSubject
            .removeDuplicates { old, new in
                NSDictionary(dictionary: Dictionary(uniqueKeysWithValues: old.map { ($0.key.rawValue, $0.value) }))
                    .isEqual(to: Dictionary(uniqueKeysWithValues: new.map { ($0.key.rawValue, $0.value) }))
            }
            .eraseToAnyPublisher()
    }

    init(
        defaults: UserDefaults = .standard,
        profileAdmission: ProfileOperationAdmission = .shared,
        walletRestoreGate: WalletBackupRestoreGate = .keychain,
        backupData: ((BackupCategory) async throws -> Data)? = nil,
        usdtRecoveryBackup: UsdtRecoveryBackupStore = UsdtRecoveryBackupStore(),
        uploadBackup: @escaping (String, Data) async throws -> Void = { key, data in
            _ = try await VssBackupClient.shared.putObject(key: key, data: data)
        },
        waitForBackupDelay: @escaping () async throws -> Void = {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        },
        waitForTemporaryFailureDelay: @escaping (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        waitForForegroundRecoveryTimeout: @escaping () async throws -> Void = {
            try await Task.sleep(for: .seconds(BackupService.backupFailureCheckInterval))
        }
    ) {
        self.defaults = defaults
        self.profileAdmission = profileAdmission
        self.walletRestoreGate = walletRestoreGate
        self.backupData = backupData
        self.usdtRecoveryBackup = usdtRecoveryBackup
        self.uploadBackup = uploadBackup
        self.waitForBackupDelay = waitForBackupDelay
        self.waitForTemporaryFailureDelay = waitForTemporaryFailureDelay
        self.waitForForegroundRecoveryTimeout = waitForForegroundRecoveryTimeout
        let statuses = getAllBackupStatuses()
        var clearedStatuses = statuses
        for category in BackupCategory.allCases {
            if let status = clearedStatuses[category], status.running {
                clearedStatuses[category] = BackupItemStatus(
                    synced: status.synced,
                    required: status.required,
                    running: false
                )
            }
        }
        if clearedStatuses != statuses {
            saveBackupStatuses(clearedStatuses)
        }

        backupStatusesSubject.send(clearedStatuses)
    }

    // MARK: - Constants

    private static let backupFailureCheckInterval: TimeInterval = 60.0 // 1 minute
    private static let failedBackupCheckTime: UInt64 = 30 * 60 // 30 minutes in seconds
    private static let failedBackupNotificationInterval: UInt64 = 10 * 60 // 10 minutes in seconds

    // MARK: - Public Methods

    /// Sets the wiping flag to prevent backups during wipe operations
    func setWiping(_ isWiping: Bool) {
        stateQueue.sync {
            self.isWiping = isWiping
        }
    }

    @MainActor
    @discardableResult
    func setAppActive(_ isActive: Bool) -> Task<Void, Never>? {
        let observingAtEntry = isObserving
        let (shouldRecover, generation) = stateQueue.sync {
            backupFailureNotificationGate.setActive(isActive)
            return (isActive && backupFailureNotificationGate.beginForegroundRecovery(), schedulingGeneration)
        }

        guard shouldRecover else { return nil }
        return Task {
            await waitForForegroundRetries(generation: generation, observingAtEntry: observingAtEntry)
            self.stateQueue.sync {
                self.backupFailureNotificationGate.endForegroundRecovery()
            }
            let shouldCheck = self.stateQueue.sync {
                self.schedulingGeneration == generation && self.backupFailureNotificationGate.shouldCheckForFailedBackups(
                    isObserving: self.isObserving
                )
            }

            guard shouldCheck else { return }
            self.checkForFailedBackups()
        }
    }

    private func waitForForegroundRetries(generation: UInt64, observingAtEntry: Bool) async {
        let (settled, finish) = AsyncStream<Void>.makeStream()
        // Bound alert suppression, not the uploads: an FFI write may ignore cancellation.
        Task {
            await self.retryPendingBackups(generation: generation, observingAtEntry: observingAtEntry)
            finish.finish()
        }
        let timeout = Task {
            do {
                try await self.waitForForegroundRecoveryTimeout()
                try Task.checkCancellation()
                finish.finish()
            } catch {}
        }
        for await _ in settled {}
        timeout.cancel()
    }

    private func retryPendingBackups(generation: UInt64, observingAtEntry: Bool) async {
        let tasks = try? await ServiceQueue.background(.backup) { [self] in
            guard observingAtEntry, !isStoppingBackups, generation == currentSchedulingGeneration else {
                return [Task<BackupOutcome, Never>]()
            }
            return BackupCategory.allCases.compactMap { category -> Task<BackupOutcome, Never>? in
                guard category != .lightningConnections, !shouldSkipBackup(category: category) else { return nil }
                let status = getBackupStatus(category: category)
                guard status.isRequired, !status.running,
                      backupJobs[category] == nil, runningBackupTasks[category] == nil
                else { return nil }

                let task = Task {
                    let outcome = await self.runBackup(category: category, isScheduled: true)
                    if outcome.canRetryPendingBackup, !Task.isCancelled, self.getBackupStatus(category: category).isRequired {
                        await self.scheduleBackup(category: category, generation: generation, initialOutcome: outcome)
                    }
                    return outcome
                }
                runningBackupTasks[category] = task
                return task
            }
        }
        for task in tasks ?? [] {
            _ = await task.value
        }
    }

    @MainActor
    @discardableResult
    func startObservingBackups() -> Task<Void, Never>? {
        let previous = observationTask
        let listeners = makeDataStoreListeners()
        let starting = Task {
            await previous?.value
            guard !shouldSkipBackup(), !isObserving else { return }
            isObserving = true
            Logger.debug("Start observing backup statuses and data store changes", context: "BackupService")
            dataStoreListeners.formUnion(listeners)
            startBackupStatusObservers()
            startPeriodicBackupFailureCheck()
        }
        observationTask = starting
        return starting
    }

    @MainActor
    func stopObservingBackups() async {
        let previous = observationTask
        let stopping = Task {
            await previous?.value
            isObserving = false
            statusListeners.removeAll()
            periodicCheckTask?.cancel()
            periodicCheckTask = nil

            let tasks = try? await ServiceQueue.background(.backup) {
                self.stateQueue.sync { self.schedulingGeneration &+= 1 }
                self.isStoppingBackups = true
                let scheduled = Array(self.backupJobs.values)
                let running = Array(self.runningBackupTasks.values)
                scheduled.forEach { $0.cancel() }
                running.forEach { $0.cancel() }
                return (scheduled, running)
            }
            // Cleanup uses the backup queue too, so drain outside it before a replacement starts.
            if let (scheduled, running) = tasks {
                for task in scheduled {
                    await task.value
                }
                for task in running {
                    _ = await task.value
                }
            }
            await walletBackupWriter.waitUntilIdle()
            await usdtBackupWriter.waitUntilIdle()
            dataStoreListeners.removeAll()
            try? await ServiceQueue.background(.backup) {
                self.isStoppingBackups = false
            }
            Logger.debug("Stopped observing backup statuses and data store changes", context: "BackupService")
        }
        observationTask = stopping
        await stopping.value
    }

    @discardableResult
    func triggerBackup(category: BackupCategory) async -> BackupOutcome {
        await triggerBackup(category: category, isScheduled: false)
    }

    private func triggerBackup(category: BackupCategory, isScheduled: Bool, waitForExisting: Bool = false) async -> BackupOutcome {
        while !Task.isCancelled {
            let admission = try? await ServiceQueue.background(.backup) { [self] () -> (
                task: Task<BackupOutcome, Never>?,
                owned: Bool,
                stopping: Bool
            ) in
                guard !isStoppingBackups else { return (nil, false, true) }
                if let existing = runningBackupTasks[category] {
                    return (waitForExisting ? existing : nil, false, false)
                }
                let task = Task { await self.runBackup(category: category, isScheduled: isScheduled) }
                runningBackupTasks[category] = task
                return (task, true, false)
            }
            guard let admission else { return .failed }
            if admission.stopping, !isScheduled {
                await waitForObservationTransition()
                continue
            }
            guard let backupTask = admission.task else { return .busy }
            return await withTaskCancellationHandler {
                await backupTask.value
            } onCancel: {
                if admission.owned {
                    backupTask.cancel()
                }
            }
        }
        return .failed
    }

    @MainActor
    private func waitForObservationTransition() async {
        await observationTask?.value
    }

    private func runBackup(category: BackupCategory, isScheduled: Bool) async -> BackupOutcome {
        Logger.debug("Backup starting for: '\(category.rawValue)'", context: "BackupService")
        var outcome = BackupOutcome.failed
        var requiredAtStart: UInt64 = 0
        var versionAtStart: UInt64 = 0
        let backupTime = UInt64(Date().timeIntervalSince1970)
        updateBackupStatus(category: category) { status in
            // Retrying must not restart the age of a backup that is already overdue.
            requiredAtStart = status.isRequired ? status.required : max(status.required, status.synced + 1, backupTime)
            versionAtStart = self.backupVersions[category, default: 0]
            return BackupItemStatus(synced: status.synced, required: requiredAtStart, running: true)
        }

        do {
            try Task.checkCancellation()
            if isScheduled, shouldSkipBackup(category: category) {
                throw CancellationError()
            }
            if category == .usdt, backupData == nil {
                try await backupUsdtRecoveryIfPresent()
            } else if category == .wallet {
                try await PaykitPaymentActivity.shared.waitUntilIdle()
                if isScheduled {
                    try await writeWalletBackup()
                } else {
                    try await persistWalletBackup()
                }
            } else {
                if category == .metadata {
                    try await prepareMetadataBackup()
                }
                let data = try await getBackupDataBytes(category: category)
                if category == .metadata {
                    try requireMetadataBackupReady()
                }
                try Task.checkCancellation()
                if isScheduled, shouldSkipBackup(category: category) {
                    throw CancellationError()
                }
                try await uploadBackup(category.rawValue, data)
            }
            updateBackupStatus(category: category) { status in
                let changed = self.backupVersions[category, default: 0] != versionAtStart
                return BackupItemStatus(
                    synced: changed ? min(requiredAtStart, status.required - 1) : max(requiredAtStart, backupTime),
                    required: status.required,
                    running: false
                )
            }
            outcome = .completed
            Logger.info("Backup succeeded for: '\(category.rawValue)'", context: "BackupService")
        } catch is CancellationError {
            updateBackupStatus(category: category) { status in
                BackupItemStatus(
                    synced: status.synced,
                    required: status.required,
                    running: false
                )
            }
        } catch {
            updateBackupStatus(category: category) { status in
                BackupItemStatus(synced: status.synced, required: status.required, running: false)
            }
            if case MetadataBackupError.deferred = error {
                outcome = .busy
                Logger.debug("Metadata backup deferred until wallet restoration and backup complete", context: "BackupService")
            } else if error is WalletBackupSnapshotError {
                outcome = .snapshotChanged
                Logger.warn("Wallet backup deferred after three changing snapshots", context: "BackupService")
            } else if Self.isTemporaryBackupFailure(error) ||
                ((category == .wallet || category == .metadata) && profileAdmission.isTransientBackupCaptureFailure(error))
            {
                outcome = .temporarilyUnavailable
                Logger.warn("Backup temporarily unavailable for: '\(category.rawValue)'", context: "BackupService")
            } else {
                Logger.error("Backup failed for: '\(category.rawValue)': \(error)", context: "BackupService")
                checkForFailedBackups()
            }
        }
        _ = try? await ServiceQueue.background(.backup) { self.runningBackupTasks.removeValue(forKey: category) }
        return outcome
    }

    private func prepareMetadataBackup() async throws {
        try Task.checkCancellation()
        guard !shouldSkipBackup(), !hasPendingWalletRestore() else { throw MetadataBackupError.deferred }
        if getBackupStatus(category: .wallet).isRequired {
            let outcome = await triggerBackup(category: .wallet, isScheduled: true, waitForExisting: true)
            try Task.checkCancellation()
            if outcome == .temporarilyUnavailable {
                throw MetadataBackupError.walletTemporarilyUnavailable
            }
            guard outcome == .completed else {
                if outcome == .busy || outcome == .snapshotChanged {
                    throw MetadataBackupError.deferred
                }
                throw MetadataBackupError.walletBackupFailed
            }
        }
        try requireMetadataBackupReady()
    }

    private func requireMetadataBackupReady() throws {
        try Task.checkCancellation()
        guard !shouldSkipBackup(), !hasPendingWalletRestore(), !getBackupStatus(category: .wallet).isRequired else {
            throw MetadataBackupError.deferred
        }
    }

    static func isTemporaryBackupFailure(_ error: Error) -> Bool {
        switch error {
        case MetadataBackupError.walletTemporarilyUnavailable,
             PaykitError.ConcurrentUpdate, PaykitError.SharedStateBusy, PaykitError.Transport,
             VssError.ConnectionError, VssError.NetworkError, VssError.StoreError, VssError.PutError:
            true
        case let VssError.UnknownError(details):
            isVssRequestSendFailure(details)
        default:
            false
        }
    }

    private static func isVssRequestSendFailure(_ details: String) -> Bool {
        let prefix = "error sending request for url ("
        guard details.hasPrefix(prefix), details.hasSuffix(")"),
              let url = URLComponents(string: String(details.dropFirst(prefix.count).dropLast())),
              url.scheme == "http" || url.scheme == "https",
              let host = url.host, !host.isEmpty,
              url.path.hasSuffix("/putObjects")
        else { return false }
        return true
    }

    func persistWalletBackup() async throws {
        do {
            try await writeWalletBackup()
        } catch {
            markBackupRequired(category: .wallet, schedule: !(error is CancellationError))
            throw error
        }
    }

    func persistUsdtRecoveryBackup(snapshot: String) async throws {
        markBackupRequired(category: .usdt, schedule: false)
        do {
            try await usdtBackupWriter.write {
                guard !self.isWipingOrRestoringUsdt() else { throw UsdtError.BackupUnavailable }
                let paymentState = try await PaykitUsdtPaymentService.shared.backupSnapshot()
                try Task.checkCancellation()
                guard !self.isWipingOrRestoringUsdt() else { throw UsdtError.BackupUnavailable }
                try await self.usdtRecoveryBackup.persist(snapshot: snapshot, paymentState: paymentState)
            }
        } catch {
            markBackupRequired(category: .usdt, schedule: !(error is CancellationError))
            throw error
        }
    }

    private func isWipingOrRestoringUsdt() -> Bool {
        stateQueue.sync { isWiping } || UsdtRecoveryRestoreGate.isPending
    }

    private func backupUsdtRecoveryIfPresent() async throws {
        guard backupData == nil else { return }
        guard let wallet = await usdtWallet else { throw UsdtError.BackupUnavailable }
        try await usdtBackupWriter.write {
            guard !self.isWipingOrRestoringUsdt() else { throw UsdtError.BackupUnavailable }
            let changes = Publishers.Merge(UsdtWalletManager.walletBackupDataChangedPublisher,
                                           PaykitUsdtPaymentService.walletBackupDataChangedPublisher).eraseToAnyPublisher()
            let tracker = WalletBackupChangeTracker(changes: changes)
            let snapshot = try await tracker.capture { () -> UsdtRecoveryBackupV1? in
                guard let core = try await wallet.backupSnapshot() else { return nil }
                return try await UsdtRecoveryBackupV1(version: 1, usdtWallet: core,
                                                      paykitUsdtState: PaykitUsdtPaymentService.shared.backupSnapshot())
            }
            guard !self.isWipingOrRestoringUsdt() else { throw UsdtError.BackupUnavailable }
            if let snapshot {
                try await self.usdtRecoveryBackup.persist(snapshot: snapshot.usdtWallet, paymentState: snapshot.paykitUsdtState)
            }
        }
    }

    /// Writes the wallet backup. The scheduler calls this directly and retries by its own rules, so its failure does not
    /// schedule another attempt; `persistWalletBackup` marks the wallet required again for every other caller.
    private func writeWalletBackup() async throws {
        try await walletBackupWriter.write {
            guard !self.shouldSkipBackup() else { throw UsdtError.BackupUnavailable }
            let data = try await self.getBackupDataBytes(category: .wallet)
            try Task.checkCancellation()
            guard !self.shouldSkipBackup() else { throw UsdtError.BackupUnavailable }
            try await self.uploadBackup(BackupCategory.wallet.rawValue, data)
        }
    }

    func hasPendingWalletRestore() -> Bool {
        if UsdtRecoveryRestoreGate.isPending {
            return true
        }
        do {
            return try walletRestoreGate.hasPendingRestore()
        } catch {
            Logger.error("Failed to read pending wallet restore state: \(error)", context: "BackupService")
            return true
        }
    }

    /// Performs full restore from latest backup
    func performFullRestoreFromLatestBackup() async throws {
        try await profileAdmission.withWalletRestore {
            try await restoreLatestBackup()
        }
    }

    private func restoreLatestBackup() async throws {
        if UsdtRecoveryRestoreGate.isPending, try !walletRestoreGate.hasPendingRestore() {
            try await restoreUsdtRecoveryAfterLegacyMigration()
            return
        }
        defer {
            setRestoring(false)
        }
        try await prepareForRestore()

        Logger.debug("Full restore starting", context: "BackupService")

        do {
            _ = try await walletRestoreGate.performRestore { retainedWalletBackup in
                try UsdtRecoveryRestoreGate.begin()
                await usdtWallet?.pauseForRecoveryRestore()
                await usdtBackupWriter.waitUntilIdle()
                await walletBackupWriter.waitUntilIdle()
                VssStoreIdProvider.shared.clearCache()
                await VssBackupClient.shared.reset()
                let walletData: Data? = if let retainedWalletBackup {
                    retainedWalletBackup
                } else {
                    try await vssBackupClient.getObject(key: BackupCategory.wallet.rawValue)?.value
                }
                if let walletData {
                    try walletRestoreGate.retain(walletData)
                }
                try await restoreUsdtRecovery(legacyWallet: walletData)
                return try await performFullRestoreFromLatestBackup(retainedWalletBackup: walletData)
            }
            markRestoreComplete(category: .wallet)
            Logger.info("Full restore success", context: "BackupService")
        } catch {
            Logger.warn("Full restore error: \(error)", context: "BackupService")
            throw error
        }
    }

    private func prepareForRestore() async throws {
        let metadataTask = try await ServiceQueue.background(.backup) {
            self.setRestoring(true)
            return self.runningBackupTasks[.metadata]
        }
        // An admitted metadata upload must finish before imported exclusions can change its wallet dependency.
        _ = await metadataTask?.value
        try Task.checkCancellation()
    }

    func restoreAppCacheData(_ cache: AppCacheData) async throws {
        try await prepareForRestore()
        if let address = cache.onchainAddress, !address.isEmpty {
            markBackupRequired(category: .wallet, schedule: false)
        }
        await SettingsViewModel.shared.restoreAppCacheData(cache)
    }

    func restoreUsdtRecoveryAfterLegacyMigration() async throws {
        try await profileAdmission.withWalletRestore {
            try await restoreMigratedUsdtRecovery()
        }
    }

    private func restoreMigratedUsdtRecovery() async throws {
        let retained = try UsdtRecoveryRestoreGate.begin()
        await usdtWallet?.pauseForRecoveryRestore()
        await usdtBackupWriter.waitUntilIdle()
        await walletBackupWriter.waitUntilIdle()
        let legacyWallet: Data? = if let retained {
            retained
        } else {
            try await usdtRecoveryBackup.get(BackupCategory.wallet.rawValue)
        }
        if let legacyWallet {
            try UsdtRecoveryRestoreGate.retain(legacyWallet)
        }
        try await restoreUsdtRecovery(legacyWallet: legacyWallet)
    }

    private func restoreUsdtRecovery(legacyWallet: Data?) async throws {
        let legacy = try legacyWallet.map { try JSONDecoder().decode(WalletBackupV1.self, from: $0) }
        try await usdtRecoveryBackup.restore(
            legacyWallet: legacy?.usdtWallet,
            legacyPaymentState: legacy?.paykitPaymentState?.usdt,
            restoreWallet: { snapshot in
                guard let wallet = await self.usdtWallet else { throw UsdtError.InvalidBackup }
                try await wallet.restoreBackup(snapshot)
            },
            restorePayments: {
                guard await self.usdtWallet != nil else { throw UsdtError.InvalidBackup }
                try await PaykitUsdtPaymentService.shared.restoreBackup($0)
            }
        )
        try UsdtRecoveryRestoreGate.complete()
        await usdtWallet?.resumeAfterRecoveryRestore()
        markRestoreComplete(category: .usdt)
    }

    private func performFullRestoreFromLatestBackup(retainedWalletBackup: Data?) async throws -> Bool {
        do {
            try await performRestore(category: .settings) { dataBytes in
                let payload = try SettingsBackupV1.decode(from: dataBytes)
                await SettingsViewModel.shared.restoreSettingsDictionary(payload.settings)
            }

            try await performRestore(category: .widgets) { dataBytes in
                let payload = try WidgetsBackupV1.decode(from: dataBytes)
                let widgets = try WidgetsBackupConverter.convertFromAndroidFormat(jsonDict: payload.widgets)
                let encodedData = try JSONEncoder().encode(widgets)
                UserDefaults.standard.set(encodedData, forKey: "savedWidgets")
            }

            var pendingPaykitSdkBackupState: String?
            var didRestoreWalletBackup = false
            // The server still holds the pre-migration envelope, so without a rewrite every future
            // restore would re-run the legacy migration. Set only once core has persisted the
            // migrated rows, so a mid-restore failure can never replace a good backup with empty
            // state.
            var categoriesNeedingRewrite: Set<BackupCategory> = []

            try await performRestore(category: .wallet, retainedData: retainedWalletBackup) { dataBytes in
                try walletRestoreGate.retain(dataBytes)
                let payload = try JSONDecoder().decode(WalletBackupV1.self, from: dataBytes)
                if let paymentState = payload.paykitPaymentState {
                    // VssBackupClient's existing custom backup namespace is explicitly wallet index 0.
                    let backupWallet = try await PaykitPaymentStateBackup.ActiveOnchainAttempt.Wallet.backupNamespace(index: 0)
                    try await PaykitPaymentProofService.shared.restoreBackup(paymentState, wallet: backupWallet)
                }
                try TransferStorage.shared.upsertList(payload.transfers)
                await PrivatePaykitAddressReservationStore.shared.restoreBackup(
                    payload.privatePaykitHighestReservedReceiveIndexByAddressType,
                    legacyPublicAddresses: payload.publicPaykitLegacyAddresses
                )
                try await WatchOnlyAccountManager.shared.restore(
                    payload.watchOnlyAccounts,
                    allocationState: payload.watchOnlyAccountAllocationState
                )
                pendingPaykitSdkBackupState = payload.paykitSdkBackupState
                didRestoreWalletBackup = true

                Logger.debug("Restored \(payload.transfers.count) transfers", context: "BackupService")
            }

            try await performRestore(category: .activity) { dataBytes in
                let migration = BackupFieldMigration.apply(dataBytes, fieldMigrations: [
                    "activities": migrateBackupActivitiesJson,
                    "activityTags": migrateBackupActivityTagsJson,
                ])
                let payload = try JSONDecoder().decode(ActivityBackupV1.self, from: AndroidBackupJson.normalized(migration.data))

                try await CoreService.shared.activity.upsertList(payload.activities)
                try await CoreService.shared.activity.upsertTags(payload.activityTags)
                try await CoreService.shared.activity.upsertClosedChannelList(payload.closedChannels)

                if migration.changed {
                    categoriesNeedingRewrite.insert(.activity)
                }

                Logger.debug(
                    "Restored \(payload.activities.count) activities, \(payload.activityTags.count) activity tags, \(payload.closedChannels.count) closed channels",
                    context: "BackupService"
                )
            }

            try await performRestore(category: .metadata) { dataBytes in
                let migration = BackupFieldMigration.apply(dataBytes, fieldMigrations: [
                    "tagMetadata": migrateBackupPreActivityMetadataJson,
                ])
                let payload = try JSONDecoder().decode(MetadataBackupV1.self, from: migration.data)

                try await restoreAppCacheData(payload.cache)
                try await CoreService.shared.activity.upsertPreActivityMetadata(payload.tagMetadata)

                if migration.changed {
                    categoriesNeedingRewrite.insert(.metadata)
                }

                try await Self.restoreProfileMetadata {
                    try await PubkyProfileManager.restoreSessionBackupState(payload.pubkySession)
                } installOverrides: {
                    ContactsManager.restoreContactProfileOverrides(payload.pubkyContactProfileOverrides)
                }

                // App-owned, so it takes no part in the core field migration above and never sets
                // needsRewrite. Restored names wait as pending ones until each wallet is paired again.
                HwKnownDeviceStorage.restoreNames(payload.hwWalletNames ?? [:])

                // Force address rotation by clearing onchain address
                UserDefaults.standard.set("", forKey: "onchainAddress")

                Logger.debug(
                    "Restored caches, \(payload.tagMetadata.count) pre-activity metadata, "
                        + "\(payload.hwWalletNames?.count ?? 0) hardware wallet names",
                    context: "BackupService"
                )
            }

            if didRestoreWalletBackup {
                try await PrivatePaykitService.shared.restoreBackup(pendingPaykitSdkBackupState)
                await PrivatePaykitAddressReservationStore.shared.reconcileReservedIndexesWithLdk()
            }

            try await performRestore(category: .blocktank) { dataBytes in
                let payload = try JSONDecoder().decode(BlocktankBackupV1.self, from: AndroidBackupJson.normalized(dataBytes))

                try await CoreService.shared.blocktank.upsertOrdersList(payload.orders)
                try await CoreService.shared.blocktank.upsertCjitEntriesList(payload.cjitEntries)

                if let info = payload.info {
                    try await CoreService.shared.blocktank.setInfo(info)
                }

                Logger.debug("Restored \(payload.orders.count) orders, \(payload.cjitEntries.count) CJITs", context: "BackupService")
            }

            // Always reset PIN settings after restore (PIN is never backed up for security)
            await SettingsViewModel.shared.resetPinSettings()

            // Other category rewrites can run during restore. Metadata remains required until the
            // wallet restore and any imported reservation backup complete; keep restore observers suppressed.
            await rewriteMigratedBackups(categoriesNeedingRewrite)

            return didRestoreWalletBackup
        }
    }

    // MARK: - Private Methods

    @MainActor
    private func startBackupStatusObservers() {
        for category in BackupCategory.allCases {
            let categoryPublisher = backupStatusesPublisher
                .prepend(getAllBackupStatuses())
                .map { statuses -> BackupItemStatus in
                    statuses[category] ?? BackupItemStatus()
                }

            let distinctPublisher = categoryPublisher
                .removeDuplicates { old, new in
                    old.synced == new.synced && old.required == new.required
                }

            distinctPublisher
                .sink { [weak self] status in
                    guard let self, !self.shouldSkipBackup(category: category) else { return }
                    if status.isRequired && !status.running {
                        let generation = currentSchedulingGeneration
                        Task {
                            await self.scheduleBackup(category: category, generation: generation)
                        }
                    }
                }
                .store(in: &statusListeners)
        }

        Logger.debug("Started \(BackupCategory.allCases.count) backup status observers", context: "BackupService")
    }

    @MainActor
    private func makeDataStoreListeners() -> Set<AnyCancellable> {
        var listeners = Set<AnyCancellable>()
        // SETTINGS
        SettingsViewModel.shared.settingsPublisher
            .sink { [weak self] _ in
                guard let self, !self.shouldSkipBackup() else { return }
                markObservedBackupRequired(category: .settings)
            }
            .store(in: &listeners)

        // WIDGETS
        SettingsViewModel.shared.widgetsPublisher
            .sink { [weak self] _ in
                guard let self, !self.shouldSkipBackup() else { return }
                markObservedBackupRequired(category: .widgets)
            }
            .store(in: &listeners)

        // Record requirements synchronously; the scheduled upload already has a debounce.
        WalletBackupChangeTracker.localChanges
            .merge(with: PaykitSdkService.walletBackupDataChangedPublisher)
            .sink { [weak self] _ in
                guard let self, !self.shouldSkipBackup() else { return }
                markObservedBackupRequired(category: .wallet)
            }
            .store(in: &listeners)

        UsdtWalletManager.walletBackupDataChangedPublisher
            .merge(with: PaykitUsdtPaymentService.walletBackupDataChangedPublisher)
            .sink { [weak self] _ in
                guard let self, !self.isWipingOrRestoringUsdt() else { return }
                markObservedBackupRequired(category: .usdt)
            }
            .store(in: &listeners)

        // ACTIVITIES
        CoreService.shared.activity.activitiesChangedPublisher
            .sink { [weak self] _ in
                guard let self, !self.shouldSkipBackup() else { return }
                markObservedBackupRequired(category: .activity)
            }
            .store(in: &listeners)

        // METADATA (from ActivityService)
        CoreService.shared.activity.metadataChangedPublisher
            .sink { [weak self] _ in
                guard let self, !self.shouldSkipBackup() else { return }
                markObservedBackupRequired(category: .metadata)
            }
            .store(in: &listeners)

        // METADATA (hardware wallet names). Scoped to the names alone: the known-device store is also
        // rewritten by every connect, and reconnect traffic must not re-upload the whole envelope.
        HwKnownDeviceStorage.namesChangedPublisher
            .sink { [weak self] _ in
                guard let self, !self.shouldSkipBackup() else { return }
                markObservedBackupRequired(category: .metadata)
            }
            .store(in: &listeners)

        // APP STATE (UserDefaults changes, etc.)
        SettingsViewModel.shared.appStatePublisher
            .sink { [weak self] _ in
                guard let self, !self.shouldSkipBackup() else { return }
                markObservedBackupRequired(category: .metadata)
            }
            .store(in: &listeners)

        // BLOCKTANK
        CoreService.shared.blocktank.stateChangedPublisher
            .sink { [weak self] _ in
                guard let self, !self.shouldSkipBackup() else { return }
                markObservedBackupRequired(category: .blocktank)
            }
            .store(in: &listeners)

        // LIGHTNING SYNC STATUS
        LightningService.shared.syncStatusChangedPublisher
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] lastSync in
                guard let self, !self.shouldSkipBackup() else { return }
                updateBackupStatus(category: .lightningConnections) { _ in
                    BackupItemStatus(
                        synced: lastSync,
                        required: lastSync,
                        running: false
                    )
                }
            }
            .store(in: &listeners)

        return listeners
    }

    private func markObservedBackupRequired(category: BackupCategory) {
        // Persist notifications during restart without admitting uploads before cleanup finishes.
        markBackupRequired(category: category, schedule: false)
        Task { @MainActor in
            await waitForObservationTransition()
            guard isObserving else { return }
            await scheduleBackup(category: category, generation: currentSchedulingGeneration)
        }
    }

    @MainActor
    private func startPeriodicBackupFailureCheck() {
        periodicCheckTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.backupFailureCheckInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                checkForFailedBackups()
            }
        }
    }

    func setRestoring(_ value: Bool) {
        stateQueue.sync { isRestoring = value }
    }

    private func shouldSkipBackup(category: BackupCategory? = nil) -> Bool {
        if category == .usdt {
            return isWipingOrRestoringUsdt()
        }
        if category == nil || category == .wallet, UsdtRecoveryRestoreGate.isPending {
            return true
        }
        return stateQueue.sync {
            isRestoring || isWiping
        }
    }

    func markBackupRequired(category: BackupCategory, schedule: Bool = true) {
        updateBackupStatus(category: category) { status in
            self.backupVersions[category, default: 0] &+= 1
            return BackupItemStatus(
                synced: status.synced,
                required: max(status.required, status.synced + 1, UInt64(Date().timeIntervalSince1970)),
                running: status.running
            )
        }

        guard schedule else { return }
        let generation = currentSchedulingGeneration
        Task { await scheduleBackup(category: category, generation: generation) }
    }

    private var currentSchedulingGeneration: UInt64 {
        stateQueue.sync { schedulingGeneration }
    }

    private func scheduleBackup(category: BackupCategory, generation: UInt64, initialOutcome: BackupOutcome = .failed) async {
        while !Task.isCancelled {
            let waitingForStop = try? await ServiceQueue.background(.backup) { [self] in
                guard generation == currentSchedulingGeneration else { return false }
                guard !isStoppingBackups else { return true }
                guard backupJobs[category] == nil, getBackupStatus(category: category).isRequired,
                      !shouldSkipBackup(category: category) else { return false }
                updateBackupStatus(category: category) { status in
                    BackupItemStatus(
                        synced: status.synced,
                        required: status.required,
                        running: true
                    )
                }
                backupJobs[category] = Task {
                    await self.runScheduledBackup(category: category, generation: generation, initialOutcome: initialOutcome)
                }
                return false
            }
            guard waitingForStop == true else { return }
            await waitForObservationTransition()
        }
    }

    /// Startup migrations run before change listeners, so their backup requirement must survive until observation starts.
    static func markWalletBackupRequiredBeforeObservation(defaults: UserDefaults) {
        var statuses = loadBackupStatuses(defaults: defaults)
        let status = statuses[.wallet] ?? BackupItemStatus()
        statuses[.wallet] = BackupItemStatus(
            synced: status.synced,
            required: max(status.required, status.synced + 1, UInt64(Date().timeIntervalSince1970)),
            running: status.running
        )
        _ = persistBackupStatuses(statuses, defaults: defaults)
    }

    private func runScheduledBackup(category: BackupCategory, generation: UInt64, initialOutcome: BackupOutcome) async {
        var outcome = initialOutcome
        var retryDelay: UInt64 = 10_000_000_000
        while !Task.isCancelled {
            do {
                if outcome == .temporarilyUnavailable {
                    try await waitForTemporaryFailureDelay(retryDelay)
                    retryDelay = min(retryDelay * 2, 300_000_000_000)
                } else {
                    retryDelay = 10_000_000_000
                    try await waitForBackupDelay()
                }
                try Task.checkCancellation()
            } catch {
                break
            }
            guard getBackupStatus(category: category).isRequired && !shouldSkipBackup(category: category) else { break }
            outcome = await triggerBackup(category: category, isScheduled: true)
            if !outcome.canRetryPendingBackup || !getBackupStatus(category: category).isRequired {
                break
            }
        }
        updateBackupStatus(category: category) { status in
            BackupItemStatus(synced: status.synced, required: status.required, running: false)
        }
        _ = try? await ServiceQueue.background(.backup) { self.backupJobs.removeValue(forKey: category) }
        if outcome.canRetryPendingBackup, !Task.isCancelled,
           getBackupStatus(category: category).isRequired, !shouldSkipBackup(category: category)
        {
            await scheduleBackup(category: category, generation: generation)
        }
    }

    private func checkForFailedBackups() {
        let currentTime = UInt64(Date().timeIntervalSince1970)
        if hasFailedBackups(at: currentTime) {
            showBackupFailureNotification()
        }
    }

    private func hasFailedBackups(at currentTime: UInt64) -> Bool {
        BackupCategory.allCases.contains { category in
            let status = getBackupStatus(category: category)
            return BackupFailureNotificationGate.hasFailedBackup(
                status,
                at: currentTime,
                failureAge: Self.failedBackupCheckTime
            )
        }
    }

    private func showBackupFailureNotification() {
        let generation = currentSchedulingGeneration
        Task { @MainActor in
            guard self.isObserving, generation == self.currentSchedulingGeneration, !self.shouldSkipBackup() else { return }
            let currentTime = UInt64(Date().timeIntervalSince1970)
            guard self.statusUpdateQueue.sync(execute: { self.hasFailedBackups(at: currentTime) }) else { return }

            let shouldNotify = self.stateQueue.sync {
                self.backupFailureNotificationGate.shouldNotify(
                    at: currentTime,
                    notificationInterval: Self.failedBackupNotificationInterval
                )
            }
            guard shouldNotify else { return }

            let backupCheckIntervalMinutes = Int(Self.backupFailureCheckInterval / 60)
            self.backupFailureSubject.send(backupCheckIntervalMinutes)
            Logger.warn("Backup failed for more than 30 minutes", context: "BackupService")
        }
    }

    func getBackupStatus(category: BackupCategory) -> BackupItemStatus {
        let statuses = getAllBackupStatuses()
        return statuses[category] ?? BackupItemStatus()
    }

    func getLatestBackupTime() async -> UInt64? {
        let timestamps = await withTaskGroup(of: UInt64?.self) { group in
            for category in BackupCategory.allCases where category != .lightningConnections && category != .usdt {
                group.addTask {
                    await self.getRemoteBackupTimestamp(category: category)
                }
            }

            var results: [UInt64] = []
            for await timestamp in group {
                if let ts = timestamp, ts > 0 {
                    results.append(ts)
                }
            }
            return results
        }

        return timestamps.max()
    }

    private func getRemoteBackupTimestamp(category: BackupCategory) async -> UInt64? {
        do {
            guard let item = try await vssBackupClient.getObject(key: category.rawValue) else {
                return nil
            }

            struct BackupWithCreatedAt: Codable {
                let createdAt: UInt64?
            }

            let backup = try JSONDecoder().decode(BackupWithCreatedAt.self, from: item.value)
            guard let createdAtMillis = backup.createdAt, createdAtMillis > 0 else {
                return nil
            }
            // Convert from milliseconds to seconds (matching Android behavior)
            return createdAtMillis / 1000
        } catch {
            Logger.warn("Failed to get remote backup timestamp for \(category.rawValue): \(error)", context: "BackupService")
            return nil
        }
    }

    func scheduleFullBackup() async {
        let generation = currentSchedulingGeneration
        let currentTime = UInt64(Date().timeIntervalSince1970)
        for category in BackupCategory.allCases {
            updateBackupStatus(category: category) { status in
                let newRequired = status.synced == 0 ? currentTime : status.required
                return BackupItemStatus(
                    synced: status.synced,
                    required: newRequired,
                    running: status.running
                )
            }
        }

        for category in BackupCategory.allCases {
            let status = getBackupStatus(category: category)
            if status.isRequired && !status.running {
                await scheduleBackup(category: category, generation: generation)
            }
        }
    }

    private func updateBackupStatus(category: BackupCategory, update: @escaping (BackupItemStatus) -> BackupItemStatus) {
        statusUpdateQueue.sync {
            var statuses = getAllBackupStatuses()
            let currentStatus = statuses[category] ?? BackupItemStatus()
            let nextStatus = update(currentStatus)
            guard statuses[category] != nextStatus else { return }
            statuses[category] = nextStatus
            saveBackupStatuses(statuses)
        }
    }

    // MARK: - Private Helpers

    func getAllBackupStatuses() -> [BackupCategory: BackupItemStatus] {
        Self.loadBackupStatuses(defaults: defaults)
    }

    private static func loadBackupStatuses(defaults: UserDefaults) -> [BackupCategory: BackupItemStatus] {
        guard let data = defaults.data(forKey: backupStatusesKey) else {
            return [:]
        }

        do {
            let decoded = try JSONDecoder().decode([String: BackupItemStatus].self, from: data)
            return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
                guard let category = BackupCategory(rawValue: key) else { return nil }
                return (category, value)
            })
        } catch {
            return [:]
        }
    }

    private func saveBackupStatuses(_ statuses: [BackupCategory: BackupItemStatus]) {
        if Self.persistBackupStatuses(statuses, defaults: defaults) {
            backupStatusesSubject.send(statuses)
        }
    }

    private static func persistBackupStatuses(_ statuses: [BackupCategory: BackupItemStatus], defaults: UserDefaults) -> Bool {
        let encoded = Dictionary(uniqueKeysWithValues: statuses.map { ($0.key.rawValue, $0.value) })

        do {
            let data = try JSONEncoder().encode(encoded)
            defaults.set(data, forKey: backupStatusesKey)

            return true
        } catch {
            Logger.error("Failed to encode backup statuses: \(error)", context: "BackupService")
            return false
        }
    }

    private func getBackupDataBytes(category: BackupCategory) async throws -> Data {
        if let backupData {
            return try await backupData(category)
        }
        switch category {
        case .usdt:
            throw UsdtError.BackupUnavailable
        case .settings:
            let settingsDict = await SettingsViewModel.shared.getSettingsDictionary()
            let payload = SettingsBackupV1(
                version: 1,
                createdAt: UInt64(Date().timeIntervalSince1970 * 1000),
                settings: settingsDict
            )
            return try payload.encode()

        case .widgets:
            let savedWidgets: [SavedWidget] = if let widgetsData = UserDefaults.standard.data(forKey: "savedWidgets") {
                try JSONDecoder().decode([SavedWidget].self, from: widgetsData)
            } else {
                []
            }

            let androidWidgetsDict = try WidgetsBackupConverter.convertToAndroidFormat(savedWidgets: savedWidgets)

            let payload = WidgetsBackupV1(
                version: 1,
                createdAt: UInt64(Date().timeIntervalSince1970 * 1000),
                widgets: androidWidgetsDict
            )
            let encoded = try payload.encode()
            Logger.debug("Widgets backup: \(savedWidgets.count) widgets, payload size: \(encoded.count) bytes", context: "BackupService")
            return encoded

        case .wallet:
            let changes = WalletBackupChangeTracker()
            let identity = try await PaykitSdkService.shared.backupIdentity()
            return try await changes.capture {
                try walletRestoreGate.requireReplacementBackupAllowed()
                let paykitBackup = try await PrivatePaykitService.shared.backupSnapshot()
                let transfers = try TransferStorage.shared.getAll()
                let privatePaykitHighestReservedReceiveIndexByAddressType = await PrivatePaykitAddressReservationStore.shared.backupSnapshot()
                let watchOnlyAccountSnapshot = try WatchOnlyAccountStore.backupSnapshot()
                let usdtSnapshot: String?
                if let wallet = await usdtWallet {
                    usdtSnapshot = try await wallet.backupSnapshot()
                } else {
                    guard !Env.isUsdtEnabled else { throw UsdtError.BackupUnavailable }
                    usdtSnapshot = nil
                }
                var paymentState = try await PaykitPaymentProofService.shared.backupSnapshot(
                    wallet: PaykitPaymentStateBackup.ActiveOnchainAttempt.Wallet.backupNamespace(index: 0)
                )
                paymentState.usdt = try await PaykitUsdtPaymentService.shared.backupSnapshot()
                let payload = await WalletBackupV1(
                    version: 1,
                    createdAt: UInt64(Date().timeIntervalSince1970 * 1000),
                    transfers: transfers,
                    privatePaykitHighestReservedReceiveIndexByAddressType: privatePaykitHighestReservedReceiveIndexByAddressType,
                    paykitSdkBackupState: paykitBackup.state,
                    watchOnlyAccounts: watchOnlyAccountSnapshot.accounts,
                    watchOnlyAccountAllocationState: watchOnlyAccountSnapshot.allocationState,
                    usdtWallet: usdtSnapshot,
                    paykitPaymentState: paymentState,
                    publicPaykitLegacyAddresses: PrivatePaykitAddressReservationStore.shared.legacyPublicAddressesSnapshot()
                )
                let data = try JSONEncoder().encode(payload)
                // Proof/attempt locks have been released before reacquiring the SDK lock.
                try await PaykitSdkService.shared.validateBackupSnapshot(version: paykitBackup.sdkVersion, identity: identity)
                try walletRestoreGate.requireReplacementBackupAllowed()
                return data
            }

        case .metadata:
            let currentTime = UInt64(Date().timeIntervalSince1970 * 1000)
            let profileGeneration = try ProfileOperationAdmission.shared.snapshot()
            let cache = await SettingsViewModel.shared.getAppCacheData()
            let (pubkySession, pubkyContactProfileOverrides) = try ProfileOperationAdmission.shared.withSynchronousOperation(access: .local) {
                try (PubkyProfileManager.snapshotSessionBackupState(), ContactsManager.backupContactProfileOverrides())
            }

            // Neither read may fall back to an empty list: this envelope is the only copy of the
            // tags, so uploading a partial payload would replace the stored ones. Throwing here
            // leaves the previous upload intact until a retry succeeds.
            let hardwareTagMetadata = try await CoreService.shared.activity.getHardwareTagsAsPreActivityMetadata()
            let storedPreActivityMetadata = try await CoreService.shared.activity.getAllPreActivityMetadata()

            // Hardware-derived records first: Core swallows attach failures, so a stored row can
            // outlive the activity it was meant for and hold tags the user has since edited. Live
            // tag state wins for those keys; stored records the derived set does not cover — a
            // restore whose device has not reconnected yet — are untouched.
            //
            // Deliberately the opposite of bitkit-android's `BackupRepo.getMetadataBackupDataBytes`,
            // which concatenates stored first and so keeps the stale row. The two only differ inside
            // that attach-failure window, and preserving what the user currently sees is the safer
            // side to land on.
            let preActivityMetadata = HwActivityTagBackup.deduplicated(hardwareTagMetadata + storedPreActivityMetadata)

            // A UserDefaults read that cannot fail, so unlike the tags above there is no partial-read
            // case to guard against. Nil rather than an empty map when nothing is named, so an
            // envelope this app writes stays byte-comparable with one bitkit-android writes.
            let hwWalletNames = HwKnownDeviceStorage.backupSnapshot()

            try ProfileOperationAdmission.shared.validate(profileGeneration)
            let payload = MetadataBackupV1(
                version: 1,
                createdAt: currentTime,
                tagMetadata: preActivityMetadata,
                cache: cache,
                pubkySession: pubkySession,
                pubkyContactProfileOverrides: pubkyContactProfileOverrides,
                hwWalletNames: hwWalletNames.isEmpty ? nil : hwWalletNames
            )
            return try JSONEncoder().encode(payload)

        case .blocktank:
            let orders = try await CoreService.shared.blocktank.orders()
            let cjitEntries = try await CoreService.shared.blocktank.cjitOrders()
            let info = try? await CoreService.shared.blocktank.info(refresh: false)

            let payload = BlocktankBackupV1(
                version: 1,
                createdAt: UInt64(Date().timeIntervalSince1970 * 1000),
                orders: orders,
                cjitEntries: cjitEntries,
                info: info
            )

            return try JSONEncoder().encode(payload)

        case .activity:
            let activities = try await CoreService.shared.activity.get()
            let closedChannels = try await CoreService.shared.activity.closedChannels()
            let activityTags = try await CoreService.shared.activity.getAllActivitiesTags()

            let payload = ActivityBackupV1(
                version: 1,
                createdAt: UInt64(Date().timeIntervalSince1970 * 1000),
                activities: activities,
                activityTags: activityTags,
                closedChannels: closedChannels
            )

            return try JSONEncoder().encode(payload)

        case .lightningConnections:
            throw NSError(
                domain: "BackupService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "LIGHTNING_CONNECTIONS backup is managed by ldk-node"]
            )
        }
    }

    /// Re-upload the envelopes whose Core-owned fields the restore had to migrate, so later restores
    /// read current wallet-scoped entries instead of re-running the legacy path forever. Uploads
    /// from the rows Core just persisted, so this can only ever publish state Core accepted.
    private func rewriteMigratedBackups(_ categories: Set<BackupCategory>) async {
        guard !categories.isEmpty else { return }

        Logger.info(
            "Rewriting migrated backups for: '\(categories.map(\.rawValue).sorted().joined(separator: ", "))'",
            context: "BackupService"
        )

        for category in categories {
            await triggerBackup(category: category)
        }
    }

    static func restoreProfileMetadata(restoreSession: () async throws -> Void, installOverrides: () -> Void) async throws {
        try await ProfileOperationAdmission.shared.withSessionTransition {
            do { try await restoreSession() }
            catch {
                // Failed local credential replacement must keep the required wallet restore pending.
                if BackupRestoreFailurePolicy.isFatal(.metadata, error: error) {
                    throw error
                }
                Logger.warn("Failed to restore pubky session backup state: \(error)", context: "BackupService")
            }
            try ProfileOperationAdmission.shared.checkCurrent()
            installOverrides()
        }
    }

    func performRestore(
        category: BackupCategory,
        retainedData: Data? = nil,
        restoreAction: (Data) async throws -> Void
    ) async throws {
        do {
            let dataBytes = if let retainedData {
                retainedData
            } else {
                try await vssBackupClient.getObject(key: category.rawValue)?.value
            }

            if let dataBytes {
                try await restoreAction(dataBytes)
                Logger.info("Restore success for: '\(category.rawValue)'", context: "BackupService")
            } else {
                Logger.warn("Restore null for: '\(category.rawValue)'", context: "BackupService")
            }
        } catch {
            // Only a total VSS failure surfaces otherwise, so without the error every category
            // fails silently. The benign "nothing backed up yet" case takes the branch above.
            Logger.warn("Restore error for: '\(category.rawValue)': \(error)", context: "BackupService")
            if BackupRestoreFailurePolicy.isFatal(category, error: error) {
                throw error
            }
        }

        if category == .wallet, try walletRestoreGate.hasPendingRestore() {
            return
        }
        markRestoreComplete(category: category)
    }

    func markRestoreComplete(category: BackupCategory) {
        let currentTime = UInt64(Date().timeIntervalSince1970)
        updateBackupStatus(category: category) { status in
            if category == .wallet, status.isRequired {
                return BackupItemStatus(synced: status.synced, required: status.required, running: false)
            }
            return BackupItemStatus(
                synced: currentTime,
                required: currentTime,
                running: false
            )
        }
    }
}

enum WalletBackupSnapshotError: Error {
    case changed
}

final class WalletBackupChangeTracker {
    static var localChanges: AnyPublisher<Void, Never> {
        Publishers.MergeMany([
            TransferStorage.shared.transfersChangedPublisher.map { _ in () }.eraseToAnyPublisher(),
            PrivatePaykitAddressReservationStore.walletBackupDataChangedPublisher,
            PrivatePaykitService.walletBackupDataChangedPublisher,
            PaykitSubscriptionStateStore.walletBackupDataChangedPublisher,
            PaykitPaymentRequestIdStore.walletBackupDataChangedPublisher,
            PaykitAllowanceKeychainStore.walletBackupDataChangedPublisher,
            PaykitPaymentProofService.proofStateChangedPublisher,
            OnchainSendAttemptStore.walletBackupDataChangedPublisher,
            UsdtWalletManager.walletBackupDataChangedPublisher,
            PaykitUsdtPaymentService.walletBackupDataChangedPublisher,
            WatchOnlyAccountStore.walletBackupDataChangedPublisher,
        ]).eraseToAnyPublisher()
    }

    private let lock = NSLock()
    private var version: UInt64 = 0
    private var subscription: AnyCancellable?

    init(changes: AnyPublisher<Void, Never> = localChanges) {
        subscription = changes.sink { [weak self] _ in
            guard let self else { return }
            lock.withLock { self.version &+= 1 }
        }
    }

    func capture<T>(_ snapshot: () async throws -> T) async throws -> T {
        for attempt in 1 ... 3 {
            try Task.checkCancellation()
            let initialVersion = lock.withLock { version }
            do {
                let result = try await snapshot()
                try Task.checkCancellation()
                guard lock.withLock({ version == initialVersion }) else { throw WalletBackupSnapshotError.changed }
                return result
            } catch WalletBackupSnapshotError.changed {
                try Task.checkCancellation()
                Logger.debug("Wallet snapshot changed during capture (attempt \(attempt)/3)", context: "BackupService")
                if attempt == 3 {
                    throw WalletBackupSnapshotError.changed
                }
            }
        }
        throw WalletBackupSnapshotError.changed
    }
}

/// The lock owns every access to subscription storage; no mutable collection escapes.
final class BackupObservationSubscriptions: @unchecked Sendable {
    private let lock = NSLock()
    private var subscriptions = Set<AnyCancellable>()

    func store(_ subscription: AnyCancellable) {
        lock.withLock { _ = subscriptions.insert(subscription) }
    }

    func cancelAll() {
        let cancelled = lock.withLock {
            let cancelled = subscriptions
            subscriptions.removeAll()
            return cancelled
        }
        // Cancellation can re-enter subscription storage; do not hold its lock across callbacks.
        cancelled.forEach { $0.cancel() }
    }
}

private extension AnyCancellable {
    func store(in subscriptions: BackupObservationSubscriptions) {
        subscriptions.store(self)
    }
}

actor WalletBackupWriter {
    private var previous: Task<Void, Error>?

    func waitUntilIdle() async {
        _ = try? await previous?.value
    }

    func write(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let preceding = previous
        let task = Task {
            _ = try? await preceding?.value
            try Task.checkCancellation()
            try await operation()
        }
        previous = task
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

struct BackupFailureNotificationGate {
    private var isActive = false
    private var isRecovering = false
    private var lastNotificationTime: UInt64?

    mutating func setActive(_ isActive: Bool) {
        self.isActive = isActive
    }

    mutating func beginForegroundRecovery() -> Bool {
        guard !isRecovering else { return false }
        isRecovering = true
        return true
    }

    mutating func endForegroundRecovery() {
        isRecovering = false
    }

    func shouldCheckForFailedBackups(isObserving: Bool) -> Bool {
        isActive && isObserving
    }

    static func hasFailedBackup(
        _ status: BackupItemStatus,
        at currentTime: UInt64,
        failureAge: UInt64
    ) -> Bool {
        status.isRequired && !status.running && currentTime >= status.required &&
            currentTime - status.required > failureAge
    }

    mutating func shouldNotify(
        at currentTime: UInt64,
        notificationInterval: UInt64
    ) -> Bool {
        guard isActive, !isRecovering else { return false }

        if let lastNotificationTime {
            guard currentTime >= lastNotificationTime,
                  currentTime - lastNotificationTime >= notificationInterval
            else {
                return false
            }
        }

        lastNotificationTime = currentTime
        return true
    }
}
