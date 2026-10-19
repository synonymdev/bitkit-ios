import BitkitCore
import Combine
import Foundation
import VssRustClientFfi

// MARK: - BackupService

enum BackupRestoreFailurePolicy {
    static func isFatal(_ category: BackupCategory) -> Bool {
        category == .wallet
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

    enum BackupOutcome {
        case completed
        case snapshotChanged
        case busy
        case failed

        var canRetryPendingBackup: Bool {
            self == .completed || self == .snapshotChanged || self == .busy
        }
    }

    private let vssBackupClient = VssBackupClient.shared
    private let walletRestoreGate = WalletBackupRestoreGate.keychain
    private let walletBackupWriter = WalletBackupWriter()
    @MainActor weak var usdtWallet: UsdtWalletManager?
    private var backupJobs: [BackupCategory: Task<Void, Never>] = [:]
    private var runningBackupTasks: [BackupCategory: Task<BackupOutcome, Never>] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var periodicCheckTask: Task<Void, Never>?
    private var isObserving = false
    private var isRestoring = false
    private var isWiping = false
    private var lastNotificationTime: UInt64 = 0

    private let defaults: UserDefaults
    private let backupData: ((BackupCategory) async throws -> Data)?
    private let uploadBackup: (String, Data) async throws -> Void
    private let waitForBackupDelay: () async throws -> Void
    private let backupStatusesKey = "backupStatuses"
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
        backupData: ((BackupCategory) async throws -> Data)? = nil,
        uploadBackup: @escaping (String, Data) async throws -> Void = { key, data in
            _ = try await VssBackupClient.shared.putObject(key: key, data: data)
        },
        waitForBackupDelay: @escaping () async throws -> Void = {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
    ) {
        self.defaults = defaults
        self.backupData = backupData
        self.uploadBackup = uploadBackup
        self.waitForBackupDelay = waitForBackupDelay
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

    func startObservingBackups() {
        guard !shouldSkipBackup() else { return }

        Task {
            let shouldStart = try? await ServiceQueue.background(.backup) {
                guard !self.isObserving else { return false }
                self.isObserving = true
                return true
            }

            guard shouldStart == true else { return }

            Logger.debug("Start observing backup statuses and data store changes", context: "BackupService")
            startBackupStatusObservers()
            startDataStoreListeners()
            startPeriodicBackupFailureCheck()
        }
    }

    func stopObservingBackups() async {
        let shouldStop = try? await ServiceQueue.background(.backup) {
            let wasObserving = self.isObserving
            self.isObserving = false

            self.backupJobs.values.forEach { $0.cancel() }
            self.backupJobs.removeAll()
            self.runningBackupTasks.values.forEach { $0.cancel() }
            self.runningBackupTasks.removeAll()
            self.periodicCheckTask?.cancel()
            self.periodicCheckTask = nil
            return wasObserving
        }

        await walletBackupWriter.waitUntilIdle()
        guard shouldStop == true else { return }
        cancellables.removeAll()
        Logger.debug("Stopped observing backup statuses and data store changes", context: "BackupService")
    }

    @discardableResult
    func triggerBackup(category: BackupCategory) async -> BackupOutcome {
        await triggerBackup(category: category, isScheduled: false)
    }

    private func triggerBackup(category: BackupCategory, isScheduled: Bool) async -> BackupOutcome {
        let backupTask = try? await ServiceQueue.background(.backup) { [self] () -> Task<BackupOutcome, Never>? in
            guard runningBackupTasks[category] == nil else { return nil }
            let backupTask = Task { await self.runBackup(category: category, isScheduled: isScheduled) }
            runningBackupTasks[category] = backupTask
            return backupTask
        }

        guard let backupTask else { return .busy }
        return await withTaskCancellationHandler {
            await backupTask.value
        } onCancel: {
            backupTask.cancel()
        }
    }

    private func runBackup(category: BackupCategory, isScheduled: Bool) async -> BackupOutcome {
        Logger.debug("Backup starting for: '\(category.rawValue)'", context: "BackupService")
        var outcome = BackupOutcome.failed
        var requiredAtStart: UInt64 = 0
        var versionAtStart: UInt64 = 0
        updateBackupStatus(category: category) { status in
            requiredAtStart = max(status.required, status.synced + 1, UInt64(Date().timeIntervalSince1970))
            versionAtStart = self.backupVersions[category, default: 0]
            return BackupItemStatus(synced: status.synced, required: requiredAtStart, running: true)
        }

        do {
            if category == .wallet {
                try await PaykitPaymentActivity.shared.waitUntilIdle()
                if isScheduled {
                    try await writeWalletBackup()
                } else {
                    try await persistWalletBackup()
                }
            } else {
                let data = try await getBackupDataBytes(category: category)
                try await uploadBackup(category.rawValue, data)
            }
            updateBackupStatus(category: category) { status in
                let changed = self.backupVersions[category, default: 0] != versionAtStart
                return BackupItemStatus(
                    synced: changed ? min(requiredAtStart, status.required - 1) : requiredAtStart,
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
                    required: category == .wallet ? status.required : status.synced,
                    running: false
                )
            }
        } catch {
            updateBackupStatus(category: category) { status in
                BackupItemStatus(synced: status.synced, required: status.required, running: false)
            }
            if error is WalletBackupSnapshotError {
                outcome = .snapshotChanged
                Logger.warn("Wallet backup deferred after three changing snapshots", context: "BackupService")
            } else {
                Logger.error("Backup failed for: '\(category.rawValue)': \(error)", context: "BackupService")
            }
        }
        _ = try? await ServiceQueue.background(.backup) { self.runningBackupTasks.removeValue(forKey: category) }
        return outcome
    }

    func persistWalletBackup(usdt: String? = nil) async throws {
        do {
            try await writeWalletBackup(usdt: usdt)
        } catch {
            markBackupRequired(category: .wallet, schedule: !(error is CancellationError))
            throw error
        }
    }

    /// Writes the wallet backup. The scheduler calls this directly and retries by its own rules, so its failure does not
    /// schedule another attempt; `persistWalletBackup` marks the wallet required again for every other caller.
    private func writeWalletBackup(usdt: String? = nil) async throws {
        try await walletBackupWriter.write {
            guard !self.shouldSkipBackup() else { throw UsdtError.BackupUnavailable }
            let data = try await self.getBackupDataBytes(category: .wallet, usdt: usdt)
            try Task.checkCancellation()
            guard !self.shouldSkipBackup() else { throw UsdtError.BackupUnavailable }
            try await self.uploadBackup(BackupCategory.wallet.rawValue, data)
        }
    }

    func hasPendingWalletRestore() -> Bool {
        do {
            return try walletRestoreGate.hasPendingRestore()
        } catch {
            Logger.error("Failed to read pending wallet restore state: \(error)", context: "BackupService")
            return true
        }
    }

    /// Performs full restore from latest backup
    func performFullRestoreFromLatestBackup() async throws {
        stateQueue.sync {
            isRestoring = true
        }

        defer {
            stateQueue.sync {
                isRestoring = false
            }
        }

        VssStoreIdProvider.shared.clearCache()
        await VssBackupClient.shared.reset()
        Logger.debug("Full restore starting", context: "BackupService")

        do {
            _ = try await walletRestoreGate.performRestore { retainedWalletBackup in
                try await performFullRestoreFromLatestBackup(retainedWalletBackup: retainedWalletBackup)
            }
            markRestoreComplete(category: .wallet)
            Logger.info("Full restore success", context: "BackupService")
        } catch {
            Logger.warn("Full restore error: \(error)", context: "BackupService")
            throw error
        }
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
                if let usdt = payload.usdtWallet {
                    guard let wallet = await self.usdtWallet else { throw UsdtError.InvalidBackup }
                    try await wallet.restoreBackup(usdt)
                }
                if let paymentState = payload.paykitPaymentState {
                    // VssBackupClient's existing custom backup namespace is explicitly wallet index 0.
                    let backupWallet = try await PaykitPaymentStateBackup.ActiveOnchainAttempt.Wallet.backupNamespace(index: 0)
                    try await PaykitPaymentProofService.shared.restoreBackup(paymentState, wallet: backupWallet)
                    if let usdt = paymentState.usdt { try await PaykitUsdtPaymentService.shared.restoreBackup(usdt) }
                }
                try TransferStorage.shared.upsertList(payload.transfers)
                await PrivatePaykitAddressReservationStore.shared.restoreBackup(payload.privatePaykitHighestReservedReceiveIndexByAddressType)
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
                let payload = try JSONDecoder().decode(ActivityBackupV1.self, from: migration.data)

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

                try await CoreService.shared.activity.upsertPreActivityMetadata(payload.tagMetadata)

                if migration.changed {
                    categoriesNeedingRewrite.insert(.metadata)
                }

                try await SettingsViewModel.shared.restoreAppCacheData(payload.cache)

                do {
                    try await PubkyProfileManager.restoreSessionBackupState(payload.pubkySession)
                } catch {
                    Logger.warn("Failed to restore pubky session backup state: \(error)", context: "BackupService")
                }
                ContactsManager.restoreContactProfileOverrides(payload.pubkyContactProfileOverrides)

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
                let payload = try JSONDecoder().decode(BlocktankBackupV1.self, from: dataBytes)

                try await CoreService.shared.blocktank.upsertOrdersList(payload.orders)
                try await CoreService.shared.blocktank.upsertCjitEntriesList(payload.cjitEntries)

                if let info = payload.info {
                    try await CoreService.shared.blocktank.setInfo(info)
                }

                Logger.debug("Restored \(payload.orders.count) orders, \(payload.cjitEntries.count) CJITs", context: "BackupService")
            }

            // Always reset PIN settings after restore (PIN is never backed up for security)
            await SettingsViewModel.shared.resetPinSettings()

            // Runs while `isRestoring` is still true, which is safe only because `triggerBackup` is
            // the one upload entry point that does not consult `shouldSkipBackup()` — adding a guard
            // there would silently strand legacy envelopes on the server. Do not clear the flag here
            // to sidestep that: it belongs to the caller (`AppScene.restoreFromMostRecentBackup`
            // wraps this in its own set/defer pair), so clearing it early would reopen that
            // suppression window and let the restore's own change traffic schedule uploads.
            await rewriteMigratedBackups(categoriesNeedingRewrite)

            return didRestoreWalletBackup
        }
    }

    // MARK: - Private Methods

    private func startBackupStatusObservers() {
        for category in BackupCategory.allCases {
            let categoryPublisher = backupStatusesPublisher
                .map { statuses -> BackupItemStatus in
                    statuses[category] ?? BackupItemStatus()
                }

            let distinctPublisher = categoryPublisher
                .removeDuplicates { old, new in
                    old.synced == new.synced && old.required == new.required
                }

            distinctPublisher
                .dropFirst()
                .sink { [weak self] status in
                    guard let self, !self.shouldSkipBackup() else { return }
                    if status.isRequired && !status.running {
                        Task {
                            await self.scheduleBackup(category: category)
                        }
                    }
                }
                .store(in: &cancellables)
        }

        Logger.debug("Started \(BackupCategory.allCases.count) backup status observers", context: "BackupService")
    }

    private func startDataStoreListeners() {
        Task { @MainActor in
            // SETTINGS
            SettingsViewModel.shared.settingsPublisher
                .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, !self.shouldSkipBackup() else { return }
                    markBackupRequired(category: .settings)
                }
                .store(in: &self.cancellables)

            // WIDGETS
            SettingsViewModel.shared.widgetsPublisher
                .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, !self.shouldSkipBackup() else { return }
                    markBackupRequired(category: .widgets)
                }
                .store(in: &self.cancellables)
        }

        // Record requirements synchronously; the scheduled upload already has a debounce.
        WalletBackupChangeTracker.localChanges
            .merge(with: PaykitSdkService.walletBackupDataChangedPublisher)
            .sink { [weak self] _ in
                guard let self, !self.shouldSkipBackup() else { return }
                markBackupRequired(category: .wallet)
            }
            .store(in: &cancellables)

        // ACTIVITIES
        CoreService.shared.activity.activitiesChangedPublisher
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.shouldSkipBackup() else { return }
                markBackupRequired(category: .activity)
            }
            .store(in: &cancellables)

        // METADATA (from ActivityService)
        CoreService.shared.activity.metadataChangedPublisher
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.shouldSkipBackup() else { return }
                markBackupRequired(category: .metadata)
            }
            .store(in: &cancellables)

        // METADATA (hardware wallet names). Scoped to the names alone: the known-device store is also
        // rewritten by every connect, and reconnect traffic must not re-upload the whole envelope.
        HwKnownDeviceStorage.namesChangedPublisher
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.shouldSkipBackup() else { return }
                markBackupRequired(category: .metadata)
            }
            .store(in: &cancellables)

        // APP STATE (UserDefaults changes, etc.)
        Task { @MainActor in
            SettingsViewModel.shared.appStatePublisher
                .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, !self.shouldSkipBackup() else { return }
                    markBackupRequired(category: .metadata)
                }
                .store(in: &self.cancellables)
        }

        // BLOCKTANK
        CoreService.shared.blocktank.stateChangedPublisher
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.shouldSkipBackup() else { return }
                markBackupRequired(category: .blocktank)
            }
            .store(in: &cancellables)

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
            .store(in: &cancellables)

        Logger.debug("Started data store listeners", context: "BackupService")
    }

    private func startPeriodicBackupFailureCheck() {
        Task {
            try? await ServiceQueue.background(.backup) {
                self.periodicCheckTask = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: UInt64(Self.backupFailureCheckInterval * 1_000_000_000))
                        guard !Task.isCancelled else { break }
                        self.checkForFailedBackups()
                    }
                }
            }
        }
    }

    func setRestoring(_ value: Bool) {
        stateQueue.sync { isRestoring = value }
    }

    private func shouldSkipBackup() -> Bool {
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
                running: schedule || status.running
            )
        }

        guard schedule else { return }
        Task {
            let status = getBackupStatus(category: category)
            if status.isRequired && !shouldSkipBackup() {
                await scheduleBackup(category: category)
            } else if !status.isRequired {
                updateBackupStatus(category: category) { status in
                    BackupItemStatus(
                        synced: status.synced,
                        required: status.required,
                        running: false
                    )
                }
            }
        }
    }

    private func scheduleBackup(category: BackupCategory) async {
        try? await ServiceQueue.background(.backup) { [self] in
            guard backupJobs[category] == nil else { return }
            updateBackupStatus(category: category) { status in
                BackupItemStatus(
                    synced: status.synced,
                    required: status.required,
                    running: true
                )
            }
            backupJobs[category] = Task { await self.runScheduledBackup(category: category) }
        }
    }

    private func runScheduledBackup(category: BackupCategory) async {
        var outcome = BackupOutcome.failed
        while !Task.isCancelled {
            do {
                try await waitForBackupDelay()
                try Task.checkCancellation()
            } catch {
                break
            }
            guard getBackupStatus(category: category).isRequired && !shouldSkipBackup() else { break }
            outcome = await triggerBackup(category: category, isScheduled: true)
            if !outcome.canRetryPendingBackup || !getBackupStatus(category: category).isRequired { break }
        }
        _ = try? await ServiceQueue.background(.backup) { self.backupJobs.removeValue(forKey: category) }
        updateBackupStatus(category: category) { status in
            BackupItemStatus(synced: status.synced, required: status.required, running: false)
        }
        if outcome.canRetryPendingBackup, !Task.isCancelled,
           getBackupStatus(category: category).isRequired, !shouldSkipBackup()
        {
            await scheduleBackup(category: category)
        }
    }

    private func checkForFailedBackups() {
        let currentTime = UInt64(Date().timeIntervalSince1970)

        let hasFailedBackups = BackupCategory.allCases.contains { category in
            let status = getBackupStatus(category: category)
            return status.isRequired &&
                currentTime > status.required &&
                (currentTime - status.required) > Self.failedBackupCheckTime
        }

        if hasFailedBackups {
            showBackupFailureNotification(currentTime: currentTime)
        }
    }

    private func showBackupFailureNotification(currentTime: UInt64) {
        Task {
            try? await ServiceQueue.background(.backup) {
                if currentTime - self.lastNotificationTime < Self.failedBackupNotificationInterval {
                    return
                }

                self.lastNotificationTime = currentTime

                let backupCheckIntervalMinutes = Int(Self.backupFailureCheckInterval / 60)
                self.backupFailureSubject.send(backupCheckIntervalMinutes)

                Logger.warn("Backup failed for more than 30 minutes", context: "BackupService")
            }
        }
    }

    func getBackupStatus(category: BackupCategory) -> BackupItemStatus {
        let statuses = getAllBackupStatuses()
        return statuses[category] ?? BackupItemStatus()
    }

    func getLatestBackupTime() async -> UInt64? {
        let timestamps = await withTaskGroup(of: UInt64?.self) { group in
            for category in BackupCategory.allCases where category != .lightningConnections {
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
                await scheduleBackup(category: category)
            }
        }
    }

    private func updateBackupStatus(category: BackupCategory, update: @escaping (BackupItemStatus) -> BackupItemStatus) {
        statusUpdateQueue.sync {
            var statuses = getAllBackupStatuses()
            let currentStatus = statuses[category] ?? BackupItemStatus()
            statuses[category] = update(currentStatus)
            saveBackupStatuses(statuses)
        }
    }

    // MARK: - Private Helpers

    func getAllBackupStatuses() -> [BackupCategory: BackupItemStatus] {
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
        let encoded = Dictionary(uniqueKeysWithValues: statuses.map { ($0.key.rawValue, $0.value) })

        do {
            let data = try JSONEncoder().encode(encoded)
            defaults.set(data, forKey: backupStatusesKey)

            backupStatusesSubject.send(statuses)
        } catch {
            Logger.error("Failed to encode backup statuses: \(error)", context: "BackupService")
        }
    }

    private func getBackupDataBytes(category: BackupCategory, usdt: String? = nil) async throws -> Data {
        if let backupData { return try await backupData(category) }
        switch category {
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
                if let usdt {
                    usdtSnapshot = usdt
                } else if let wallet = await usdtWallet {
                    usdtSnapshot = try await wallet.backupSnapshot()
                } else {
                    guard !Env.isUsdtEnabled else { throw UsdtError.BackupUnavailable }
                    usdtSnapshot = nil
                }
                var paymentState = try await PaykitPaymentProofService.shared.backupSnapshot(
                    wallet: PaykitPaymentStateBackup.ActiveOnchainAttempt.Wallet.backupNamespace(index: 0)
                )
                paymentState.usdt = try await PaykitUsdtPaymentService.shared.backupSnapshot()
                let payload = WalletBackupV1(
                    version: 1,
                    createdAt: UInt64(Date().timeIntervalSince1970 * 1000),
                    transfers: transfers,
                    privatePaykitHighestReservedReceiveIndexByAddressType: privatePaykitHighestReservedReceiveIndexByAddressType,
                    paykitSdkBackupState: paykitBackup.state,
                    watchOnlyAccounts: watchOnlyAccountSnapshot.accounts,
                    watchOnlyAccountAllocationState: watchOnlyAccountSnapshot.allocationState,
                    usdtWallet: usdtSnapshot,
                    paykitPaymentState: paymentState
                )
                let data = try JSONEncoder().encode(payload)
                // Proof/attempt locks have been released before reacquiring the SDK lock.
                try await PaykitSdkService.shared.validateBackupSnapshot(version: paykitBackup.sdkVersion, identity: identity)
                try walletRestoreGate.requireReplacementBackupAllowed()
                return data
            }

        case .metadata:
            let currentTime = UInt64(Date().timeIntervalSince1970 * 1000)
            let cache = try await SettingsViewModel.shared.getAppCacheData()
            let pubkySession = try PubkyProfileManager.snapshotSessionBackupState()
            let pubkyContactProfileOverrides = ContactsManager.backupContactProfileOverrides()

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

    private func performRestore(
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
            if BackupRestoreFailurePolicy.isFatal(category) {
                throw error
            }
        }

        if category == .wallet, try walletRestoreGate.hasPendingRestore() {
            return
        }
        markRestoreComplete(category: category)
    }

    private func markRestoreComplete(category: BackupCategory) {
        let currentTime = UInt64(Date().timeIntervalSince1970)
        updateBackupStatus(category: category) { _ in
            BackupItemStatus(
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
                if attempt == 3 { throw WalletBackupSnapshotError.changed }
            }
        }
        throw WalletBackupSnapshotError.changed
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
