import BitkitCore
import Combine
import Foundation
import VssRustClientFfi

// MARK: - BackupService

class BackupService {
    static let shared = BackupService()

    private let vssBackupClient = VssBackupClient.shared
    private var backupJobs: [BackupCategory: Task<Void, Never>] = [:]
    private var runningBackupTasks: [BackupCategory: Task<Void, Never>] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var periodicCheckTask: Task<Void, Never>?
    private var isObserving = false
    private var isRestoring = false
    private var lastNotificationTime: UInt64 = 0

    private let defaults = UserDefaults.standard
    private let backupStatusesKey = "backupStatuses"

    private let statusUpdateQueue = DispatchQueue(label: "backup-service-status-update", qos: .userInitiated)
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

    private init() {
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

    private static let backupDebounce: TimeInterval = 5.0 // 5 seconds
    private static let backupFailureCheckInterval: TimeInterval = 60.0 // 1 minute
    private static let failedBackupCheckTime: UInt64 = 30 * 60 // 30 minutes in seconds
    private static let failedBackupNotificationInterval: UInt64 = 10 * 60 // 10 minutes in seconds

    // MARK: - Public Methods

    func startObservingBackups() {
        Task {
            let shouldStart = try? await ServiceQueue.background(.backup) {
                guard !self.isObserving else { return false }
                self.isObserving = true
                return true
            }

            guard shouldStart == true else { return }

            try? await vssBackupClient.setup()
            Logger.debug("Start observing backup statuses and data store changes", context: "BackupService")
            startBackupStatusObservers()
            startDataStoreListeners()
            startPeriodicBackupFailureCheck()
        }
    }

    func stopObservingBackups() {
        Task {
            let shouldStop = try? await ServiceQueue.background(.backup) {
                guard self.isObserving else { return false }
                self.isObserving = false

                self.backupJobs.values.forEach { $0.cancel() }
                self.backupJobs.removeAll()
                self.runningBackupTasks.values.forEach { $0.cancel() }
                self.runningBackupTasks.removeAll()
                self.periodicCheckTask?.cancel()
                self.periodicCheckTask = nil
                return true
            }

            guard shouldStop == true else { return }
            cancellables.removeAll()
            Logger.debug("Stopped observing backup statuses and data store changes", context: "BackupService")
        }
    }

    func triggerBackup(category: BackupCategory) async {
        let existingTask = try? await ServiceQueue.background(.backup) { self.runningBackupTasks[category] }
        if let existingTask, !existingTask.isCancelled {
            return
        }

        let backupTask = Task {
            Logger.debug("Backup starting for: '\(category.rawValue)'", context: "BackupService")

            updateBackupStatus(category: category) { status in
                BackupItemStatus(
                    synced: status.synced,
                    required: UInt64(Date().timeIntervalSince1970),
                    running: true
                )
            }

            do {
                try await vssBackupClient.setup()

                let data = try await getBackupDataBytes(category: category)
                let _ = try await vssBackupClient.putObject(key: category.rawValue, data: data)

                updateBackupStatus(category: category) { status in
                    BackupItemStatus(
                        synced: UInt64(Date().timeIntervalSince1970),
                        required: status.required,
                        running: false
                    )
                }

                Logger.info("Backup succeeded for: '\(category.rawValue)'", context: "BackupService")
            } catch let error as CancellationError {
                updateBackupStatus(category: category) { status in
                    BackupItemStatus(
                        synced: status.synced,
                        required: status.synced,
                        running: false
                    )
                }
            } catch {
                updateBackupStatus(category: category) { status in
                    BackupItemStatus(
                        synced: status.synced,
                        required: status.required,
                        running: false
                    )
                }
                Logger.error("Backup failed for: '\(category.rawValue)': \(error)", context: "BackupService")
            }

            try? await ServiceQueue.background(.backup) { self.runningBackupTasks.removeValue(forKey: category) }
        }

        try? await ServiceQueue.background(.backup) { self.runningBackupTasks[category] = backupTask }
        await backupTask.value
    }

    /// Performs full restore from latest backup
    func performFullRestoreFromLatestBackup() async {
        try? await ServiceQueue.background(.backup) { self.isRestoring = true }

        VssStoreIdProvider.shared.clearCache()
        VssBackupClient.shared.reset()

        Logger.debug("Full restore starting", context: "BackupService")

        do {
            try await performRestore(category: .settings) { dataBytes in
                guard let settingsDict = try JSONSerialization.jsonObject(with: dataBytes) as? [String: Any] else {
                    throw NSError(domain: "BackupService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse settings JSON"])
                }

                await SettingsViewModel.shared.restoreSettingsDictionary(settingsDict)
            }

            try await performRestore(category: .widgets) { dataBytes in
                guard let jsonDict = try JSONSerialization.jsonObject(with: dataBytes) as? [String: Any] else {
                    throw NSError(domain: "BackupService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid widgets format"])
                }

                let decodedWidgets = try WidgetsBackupConverter.convertFromAndroidFormat(jsonDict: jsonDict)
                let encodedData = try JSONEncoder().encode(decodedWidgets)
                UserDefaults.standard.set(encodedData, forKey: "savedWidgets")
            }

            try await performRestore(category: .wallet) { dataBytes in
                let payload = try JSONDecoder().decode(WalletBackupV1.self, from: dataBytes)
                try TransferStorage.shared.upsertList(payload.transfers)

                Logger.debug("Restored \(payload.transfers.count) transfers", context: "BackupService")
            }

            try await performRestore(category: .activity) { dataBytes in
                let payload = try JSONDecoder().decode(ActivityBackupV1.self, from: dataBytes)

                try await CoreService.shared.activity.upsertList(payload.activities)
                try await CoreService.shared.activity.upsertClosedChannelList(payload.closedChannels)

                Logger.debug(
                    "Restored \(payload.activities.count) activities, \(payload.closedChannels.count) closed channels",
                    context: "BackupService"
                )
            }

            try await performRestore(category: .metadata) { dataBytes in
                let payload = try JSONDecoder().decode(MetadataBackupV1.self, from: dataBytes)

                let activityTags = payload.tagMetadata.map { item in
                    ActivityTags(activityId: item.id, tags: item.tags)
                }

                try await CoreService.shared.activity.upsertTags(activityTags)

                await SettingsViewModel.shared.restoreAppCacheData(payload.cache)

                Logger.debug("Restored caches and \(payload.tagMetadata.count) tags metadata records", context: "BackupService")
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

            Logger.info("Full restore success", context: "BackupService")
        } catch {
            Logger.warn("Full restore error: \(error)", context: "BackupService")
        }

        try? await ServiceQueue.background(.backup) { self.isRestoring = false }
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
                    guard let self else { return }
                    Task {
                        let isRestoring = try? await ServiceQueue.background(.backup) { self.isRestoring }
                        guard isRestoring != true else { return }

                        if status.isRequired && !status.running {
                            await self.scheduleBackup(category: category)
                        }
                    }
                }
                .store(in: &cancellables)
        }

        Logger.debug("Started \(BackupCategory.allCases.count) backup status observers", context: "BackupService")
    }

    private func startDataStoreListeners() {
        // SETTINGS
        SettingsViewModel.shared.settingsPublisher
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isRestoring else { return }
                markBackupRequired(category: .settings)
            }
            .store(in: &cancellables)

        // WIDGETS
        SettingsViewModel.shared.widgetsPublisher
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isRestoring else { return }
                markBackupRequired(category: .widgets)
            }
            .store(in: &cancellables)

        // TRANSFERS
        TransferStorage.shared.transfersChangedPublisher
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isRestoring else { return }
                markBackupRequired(category: .wallet)
            }
            .store(in: &cancellables)

        // ACTIVITIES (triggers both metadata and activity backups)
        CoreService.shared.activity.activitiesChangedPublisher
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isRestoring else { return }
                markBackupRequired(category: .metadata)
                markBackupRequired(category: .activity)
            }
            .store(in: &cancellables)

        SettingsViewModel.shared.appStatePublisher
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isRestoring else { return }
                markBackupRequired(category: .metadata)
            }
            .store(in: &cancellables)

        // BLOCKTANK
        CoreService.shared.blocktank.stateChangedPublisher
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isRestoring else { return }
                markBackupRequired(category: .blocktank)
            }
            .store(in: &cancellables)

        // LIGHTNING SYNC STATUS
        LightningService.shared.syncStatusChangedPublisher
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] lastSync in
                guard let self, !self.isRestoring else { return }
                updateBackupStatus(category: .lightningConnections) { _ in
                    BackupItemStatus(
                        synced: lastSync,
                        required: lastSync,
                        running: false
                    )
                }
            }
            .store(in: &cancellables)

        Logger.debug("Started 7 data store listeners", context: "BackupService")
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

    private func markBackupRequired(category: BackupCategory) {
        updateBackupStatus(category: category) { status in
            BackupItemStatus(
                synced: status.synced,
                required: UInt64(Date().timeIntervalSince1970),
                running: true
            )
        }

        Task {
            let status = getBackupStatus(category: category)
            let isCurrentlyRestoring = try? await ServiceQueue.background(.backup) { self.isRestoring }
            if status.isRequired && isCurrentlyRestoring != true {
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
        let hasExistingTask = try? await ServiceQueue.background(.backup) {
            if let existingTask = self.backupJobs[category], !existingTask.isCancelled {
                return true
            }
            return false
        }

        if hasExistingTask == true {
            return
        }

        let currentStatus = getBackupStatus(category: category)
        if !currentStatus.running {
            updateBackupStatus(category: category) { status in
                BackupItemStatus(
                    synced: status.synced,
                    required: status.required,
                    running: true
                )
            }
        }

        let backupTask = Task {
            defer {
                Task {
                    try? await ServiceQueue.background(.backup) {
                        self.backupJobs.removeValue(forKey: category)
                    }
                }
            }

            try? await Task.sleep(nanoseconds: UInt64(Self.backupDebounce * 1_000_000_000))

            guard !Task.isCancelled else {
                updateBackupStatus(category: category) { status in
                    BackupItemStatus(synced: status.synced, required: status.required, running: false)
                }
                return
            }

            let status = getBackupStatus(category: category)
            let isCurrentlyRestoring = try? await ServiceQueue.background(.backup) { self.isRestoring }
            if status.isRequired && isCurrentlyRestoring != true {
                await triggerBackup(category: category)
            } else {
                updateBackupStatus(category: category) { status in
                    BackupItemStatus(synced: status.synced, required: status.required, running: false)
                }
            }
        }

        try? await ServiceQueue.background(.backup) {
            self.backupJobs[category]?.cancel()
            self.backupJobs[category] = backupTask
        }
    }

    private func checkForFailedBackups() {
        let currentTime = UInt64(Date().timeIntervalSince1970)

        let hasFailedBackups = BackupCategory.allCases.contains { category in
            let status = getBackupStatus(category: category)
            return status.isRequired &&
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

    func getLatestBackupTime() -> UInt64? {
        let statuses = getAllBackupStatuses()
        let syncedTimestamps = BackupCategory.allCases.compactMap { category -> UInt64? in
            let status = statuses[category] ?? BackupItemStatus()
            return status.synced > 0 ? status.synced : nil
        }

        return syncedTimestamps.max()
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

    private func getBackupDataBytes(category: BackupCategory) async throws -> Data {
        switch category {
        case .settings:
            let settingsDict = await SettingsViewModel.shared.getSettingsDictionary()
            return try JSONSerialization.data(withJSONObject: settingsDict, options: [])

        case .widgets:
            guard let widgetsData = UserDefaults.standard.data(forKey: "savedWidgets") else {
                return Data()
            }

            do {
                let savedWidgets = try JSONDecoder().decode([SavedWidget].self, from: widgetsData)
                return try WidgetsBackupConverter.convertToAndroidFormat(savedWidgets: savedWidgets)
            } catch {
                return widgetsData
            }

        case .wallet:
            let transfers = try TransferStorage.shared.getAll()
            let payload = WalletBackupV1(
                version: 1,
                createdAt: UInt64(Date().timeIntervalSince1970),
                transfers: transfers
            )
            return try JSONEncoder().encode(payload)

        case .metadata:
            let currentTime = UInt64(Date().timeIntervalSince1970)
            let tagMetadata = try await CoreService.shared.activity.getAllTagMetadata()
            let cache = await SettingsViewModel.shared.getAppCacheData()

            let payload = MetadataBackupV1(
                version: 1,
                createdAt: currentTime,
                tagMetadata: tagMetadata,
                cache: cache
            )
            return try JSONEncoder().encode(payload)

        case .blocktank:
            let orders = try await CoreService.shared.blocktank.orders()
            let cjitEntries = try await CoreService.shared.blocktank.cjitOrders()
            let info = try? await CoreService.shared.blocktank.info(refresh: false)

            let payload = BlocktankBackupV1(
                version: 1,
                createdAt: UInt64(Date().timeIntervalSince1970),
                orders: orders,
                cjitEntries: cjitEntries,
                info: info
            )

            return try JSONEncoder().encode(payload)

        case .activity:
            let activities = try await CoreService.shared.activity.get()
            let closedChannels = try await CoreService.shared.activity.closedChannels()

            let payload = ActivityBackupV1(
                version: 1,
                createdAt: UInt64(Date().timeIntervalSince1970),
                activities: activities,
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

    private func performRestore(category: BackupCategory, restoreAction: (Data) async throws -> Void) async throws {
        do {
            let item = try await vssBackupClient.getObject(key: category.rawValue)

            if let item {
                try await restoreAction(item.value)
                Logger.info("Restore success for: '\(category.rawValue)'", context: "BackupService")
            } else {
                Logger.warn("Restore null for: '\(category.rawValue)'", context: "BackupService")
            }
        } catch {
            Logger.debug("Restore error for: '\(category.rawValue)'", context: "BackupService")
        }

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
