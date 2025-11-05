import Combine
import Foundation
import SwiftUI

/// ViewModel for backup status and operations
@MainActor
class BackupViewModel: ObservableObject {
    @Published var backupStatuses: [BackupCategory: BackupItemStatus] = [:]

    private var cancellables = Set<AnyCancellable>()

    init() {
        backupStatuses = BackupService.shared.getAllBackupStatuses()

        BackupService.shared.backupStatusesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] statuses in
                self?.backupStatuses = statuses
            }
            .store(in: &cancellables)
    }

    /// Gets the backup status for a specific category
    func getStatus(for category: BackupCategory) -> BackupItemStatus {
        return backupStatuses[category] ?? BackupItemStatus()
    }

    /// Formats the status text for display
    func formatStatusText(for category: BackupCategory) -> String {
        let status = getStatus(for: category)

        if status.running {
            return "Running"
        }

        if status.synced < status.required {
            return "Required"
        }

        if status.synced > 0 {
            let syncedDate = Date(timeIntervalSince1970: TimeInterval(status.synced))
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale.current
            formatter.dateTimeStyle = .named
            formatter.unitsStyle = .full

            let relativeTime = formatter.localizedString(for: syncedDate, relativeTo: Date())
            return relativeTime.prefix(1).uppercased() + relativeTime.dropFirst()
        }

        return "Never"
    }

    /// Triggers a backup for the specified category
    func triggerBackup(for category: BackupCategory) {
        Task {
            await BackupService.shared.triggerBackup(category: category)
        }
    }
}
