import Combine
import Foundation
import VssRustClientFfi

// MARK: - Notification Names

extension Notification.Name {
    static let backupFailureNotification = Notification.Name("backupFailureNotification")
}

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

    /// Publisher that emits when backup statuses change
    var backupStatusesPublisher: AnyPublisher<[BackupCategory: BackupItemStatus], Never> {
        backupStatusesSubject
            .removeDuplicates { old, new in
                NSDictionary(dictionary: Dictionary(uniqueKeysWithValues: old.map { ($0.key.rawValue, $0.value) }))
                    .isEqual(to: Dictionary(uniqueKeysWithValues: new.map { ($0.key.rawValue, $0.value) }))
            }
            .eraseToAnyPublisher()
    }

    private init() {
        backupStatusesSubject.send(getAllBackupStatuses())
    }

    // MARK: - Constants

    private static let backupDebounce: TimeInterval = 5.0 // 5 seconds
    private static let backupFailureCheckInterval: TimeInterval = 60.0 // 1 minute
    private static let failedBackupCheckTime: UInt64 = 30 * 60 // 30 minutes in seconds
    private static let failedBackupNotificationInterval: UInt64 = 10 * 60 // 10 minutes in seconds

    // MARK: - Public Methods

    func startObservingBackups() {
        guard !isObserving else { return }

        isObserving = true
        Logger.debug("Start observing backup statuses and data store changes", context: "BackupService")

        Task {
            try? await vssBackupClient.setup()
        }

        startBackupStatusObservers()
        startDataStoreListeners()
        startPeriodicBackupFailureCheck()
    }

    func stopObservingBackups() {
        guard isObserving else { return }

        isObserving = false

        backupJobs.values.forEach { $0.cancel() }
        backupJobs.removeAll()
        runningBackupTasks.values.forEach { $0.cancel() }
        runningBackupTasks.removeAll()
        periodicCheckTask?.cancel()
        periodicCheckTask = nil
        cancellables.removeAll()

        Logger.debug("Stopped observing backup statuses and data store changes", context: "BackupService")
    }

    func triggerBackup(category: BackupCategory) async {
        // Check if backup is already running for this category
        if let existingTask = runningBackupTasks[category], !existingTask.isCancelled {
            Logger.debug("Backup already running for: '\(category.rawValue)', skipping duplicate trigger", context: "BackupService")
            return
        }

        Logger.debug("Backup starting for: '\(category.rawValue)'", context: "BackupService")

        // Track the running backup task
        let backupTask = Task {
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
                // If backup was cancelled, don't retry - clear the required timestamp to prevent retry loop
                updateBackupStatus(category: category) { status in
                    BackupItemStatus(
                        synced: status.synced,
                        required: status.synced,
                        running: false
                    )
                }
                Logger.debug("Backup cancelled for: '\(category.rawValue)'", context: "BackupService")
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

            // Remove from running tasks when done
            runningBackupTasks.removeValue(forKey: category)
        }

        runningBackupTasks[category] = backupTask
        await backupTask.value
    }

    /// Performs full restore from latest backup
    func performFullRestoreFromLatestBackup() async {
        Logger.debug("Full restore starting", context: "BackupService")

        isRestoring = true
        defer { isRestoring = false }

        do {
            try await performRestore(category: .settings) { dataBytes in
                guard let settingsDict = try JSONSerialization.jsonObject(with: dataBytes) as? [String: Any] else {
                    throw NSError(domain: "BackupService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse settings JSON"])
                }
                SettingsStore.shared.restoreSettingsDictionary(settingsDict)
                Logger.info("Settings restored successfully", context: "BackupService")
            }

            try await performRestore(category: .widgets) { dataBytes in
                guard let jsonDict = try JSONSerialization.jsonObject(with: dataBytes) as? [String: Any] else {
                    throw NSError(domain: "BackupService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid widgets format"])
                }

                let decodedWidgets = try WidgetsBackupConverter.convertFromAndroidFormat(jsonDict: jsonDict)
                let encodedData = try JSONEncoder().encode(decodedWidgets)
                UserDefaults.standard.set(encodedData, forKey: "savedWidgets")
                Logger.info("Widgets restored successfully, count: \(decodedWidgets.count)", context: "BackupService")
            }

            Logger.info("Full restore completed", context: "BackupService")
        } catch {
            Logger.warn("Full restore error: \(error)", context: "BackupService")
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
                    guard let self, !self.isRestoring else { return }

                    if status.synced < status.required && !status.running {
                        scheduleBackup(category: category)
                    }
                }
                .store(in: &cancellables)
        }

        Logger.debug("Started \(BackupCategory.allCases.count) reactive backup status observers", context: "BackupService")
    }

    private func startDataStoreListeners() {
        SettingsStore.shared.settingsPublisher
            .sink { [weak self] _ in
                guard let self, !self.isRestoring else { return }
                markBackupRequired(category: .settings)
            }
            .store(in: &cancellables)

        SettingsStore.shared.widgetsPublisher
            .sink { [weak self] _ in
                guard let self, !self.isRestoring else { return }
                markBackupRequired(category: .widgets)
            }
            .store(in: &cancellables)

        Logger.debug("Started 2 data store listeners", context: "BackupService")
    }

    private func startPeriodicBackupFailureCheck() {
        periodicCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.backupFailureCheckInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                self?.checkForFailedBackups()
            }
        }
    }

    private func markBackupRequired(category: BackupCategory) {
        updateBackupStatus(category: category) { status in
            // Always update required timestamp to current time when data changes
            // Even if backup is running, we want to track that new changes came in
            BackupItemStatus(
                synced: status.synced,
                required: UInt64(Date().timeIntervalSince1970),
                running: status.running
            )
        }
        Logger.debug("Marked backup required for: '\(category.rawValue)'", context: "BackupService")

        // Immediately check if backup should be scheduled (in case this is the first time)
        // The reactive observer will also handle this, but this ensures immediate action
        let status = getBackupStatus(category: category)
        if status.synced < status.required && !status.running && !isRestoring {
            scheduleBackup(category: category)
        }
    }

    private func scheduleBackup(category: BackupCategory) {
        // Check if backup is already running - if so, don't reschedule
        let currentStatus = getBackupStatus(category: category)
        if currentStatus.running {
            Logger.debug("Backup already running for: '\(category.rawValue)', skipping reschedule", context: "BackupService")
            return
        }

        // Cancel existing scheduled backup job for this category (if any)
        backupJobs[category]?.cancel()

        Logger.debug("Scheduling backup for: '\(category.rawValue)'", context: "BackupService")

        let backupTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.backupDebounce * 1_000_000_000))

            // Double-check if backup is still needed and not already running
            let status = getBackupStatus(category: category)
            if status.synced < status.required && !status.running && !isRestoring {
                await triggerBackup(category: category)
            }
        }

        backupJobs[category] = backupTask
    }

    private func checkForFailedBackups() {
        let currentTime = UInt64(Date().timeIntervalSince1970)

        let hasFailedBackups = BackupCategory.allCases.contains { category in
            let status = getBackupStatus(category: category)
            return status.synced < status.required &&
                (currentTime - status.required) > Self.failedBackupCheckTime
        }

        if hasFailedBackups {
            showBackupFailureNotification(currentTime: currentTime)
        }
    }

    private func showBackupFailureNotification(currentTime: UInt64) {
        // Throttle notifications
        if currentTime - lastNotificationTime < Self.failedBackupNotificationInterval {
            return
        }

        lastNotificationTime = currentTime

        let backupCheckIntervalMinutes = Int(Self.backupFailureCheckInterval / 60)
        NotificationCenter.default.post(
            name: .backupFailureNotification,
            object: nil,
            userInfo: ["interval": backupCheckIntervalMinutes]
        )

        Logger.warn("Backup failed for more than 30 minutes", context: "BackupService")
    }

    func getBackupStatus(category: BackupCategory) -> BackupItemStatus {
        let statuses = getAllBackupStatuses()
        return statuses[category] ?? BackupItemStatus()
    }

    private func updateBackupStatus(category: BackupCategory, update: @escaping (BackupItemStatus) -> BackupItemStatus) {
        statusUpdateQueue.sync { [weak self] in
            guard let self else { return }

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
            Logger.error("Failed to decode backup statuses: \(error)", context: "BackupService")
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
            let settingsDict = SettingsStore.shared.getSettingsDictionary()
            return try JSONSerialization.data(withJSONObject: settingsDict, options: [])

        case .widgets:
            guard let widgetsData = UserDefaults.standard.data(forKey: "savedWidgets") else {
                return Data()
            }

            do {
                let savedWidgets = try JSONDecoder().decode([SavedWidget].self, from: widgetsData)
                return try WidgetsBackupConverter.convertToAndroidFormat(savedWidgets: savedWidgets)
            } catch {
                Logger.error("Failed to convert widgets to Android format: \(error)", context: "BackupService")
                return widgetsData
            }

        case .wallet, .metadata, .blocktank, .slashtags, .ldkActivity, .lightningConnections:
            throw NSError(domain: "BackupService", code: -1, userInfo: [NSLocalizedDescriptionKey: "\(category.rawValue) backup not yet implemented"])
        }
    }

    private func performRestore(category: BackupCategory, restoreAction: (Data) async throws -> Void) async throws {
        do {
            let item = try await vssBackupClient.getObject(key: category.rawValue)

            if let item {
                try await restoreAction(item.value)
                Logger.info("Restore success for: '\(category.rawValue)'", context: "BackupService")
            } else {
                Logger.warn("Restore null for: '\(category.rawValue)' - no backup found", context: "BackupService")
            }
        } catch {
            Logger.error("Restore error for: '\(category.rawValue)': \(error)", context: "BackupService")
        }

        updateBackupStatus(category: category) { status in
            BackupItemStatus(
                synced: UInt64(Date().timeIntervalSince1970),
                required: status.required,
                running: false
            )
        }
    }
}
