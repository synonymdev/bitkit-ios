import SwiftUI

enum SheetID: String, CaseIterable {
    case addTag
    case appUpdate
    case backup
    case boost
    case highBalance
    case lnurlWithdraw
    case notifications
    case quickpay
    case receive
    case receivedTx
    case scanner
    case security
    case send
}

struct SheetConfiguration {
    let id: SheetID
    let data: Any?
}

class SheetViewModel: ObservableObject {
    @Published var activeSheetConfiguration: SheetConfiguration? = nil

    func showSheet(_ id: SheetID, data: Any? = nil) {
        if isAnySheetOpen {
            // If any other sheet is open, close it and delay before showing the new sheet
            // to prevent the new sheet from closing immediately (bug)
            hideSheet()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self else { return }
                self.activeSheetConfiguration = SheetConfiguration(id: id, data: data)
                self.playHaptics(for: id)

                // Notify timed sheet manager
                Task { @MainActor in
                    TimedSheetManager.shared.onSheetShown()
                }
            }
        } else {
            // If no sheet is open, show the new sheet immediately
            activeSheetConfiguration = SheetConfiguration(id: id, data: data)
            playHaptics(for: id)

            // Notify timed sheet manager
            Task { @MainActor in
                TimedSheetManager.shared.onSheetShown()
            }
        }
    }

    func hideSheet() {
        activeSheetConfiguration = nil

        // Notify timed sheet manager
        Task { @MainActor in
            TimedSheetManager.shared.onSheetDismissed()
        }
    }

    var isAnySheetOpen: Bool {
        return activeSheetConfiguration != nil
    }

    private func playHaptics(for sheetId: SheetID) {
        sheetId == .receivedTx ? Haptics.notify(.success) : Haptics.play(.openSheet)
    }

    // MARK: - Adapter Properties for SwiftUI Sheet Presentation

    var addTagSheetItem: AddTagSheetItem? {
        get {
            guard let config = activeSheetConfiguration, config.id == .addTag else { return nil }
            let addTagConfig = config.data as? AddTagConfig
            guard let activityId = addTagConfig?.activityId else { return nil }
            return AddTagSheetItem(activityId: activityId)
        }
        set {
            if newValue == nil {
                activeSheetConfiguration = nil
            }
        }
    }

    var appUpdateSheetItem: AppUpdateSheetItem? {
        get {
            guard let config = activeSheetConfiguration, config.id == .appUpdate else { return nil }
            return AppUpdateSheetItem()
        }
        set {
            if newValue == nil {
                activeSheetConfiguration = nil
            }
        }
    }

    var backupSheetItem: BackupSheetItem? {
        get {
            guard let config = activeSheetConfiguration, config.id == .backup else { return nil }
            let backupConfig = config.data as? BackupConfig
            let initialRoute = backupConfig?.initialRoute ?? .intro
            return BackupSheetItem(initialRoute: initialRoute)
        }
        set {
            if newValue == nil {
                activeSheetConfiguration = nil
            }
        }
    }

    var boostSheetItem: BoostSheetItem? {
        get {
            guard let config = activeSheetConfiguration, config.id == .boost else { return nil }
            let boostConfig = config.data as? BoostConfig
            guard let onchainActivity = boostConfig?.onchainActivity else { return nil }
            return BoostSheetItem(onchainActivity: onchainActivity)
        }
        set {
            if newValue == nil {
                activeSheetConfiguration = nil
            }
        }
    }

    var highBalanceSheetItem: HighBalanceSheetItem? {
        get {
            guard let config = activeSheetConfiguration, config.id == .highBalance else { return nil }
            return HighBalanceSheetItem()
        }
        set {
            if newValue == nil {
                activeSheetConfiguration = nil
            }
        }
    }

    var lnurlWithdrawSheetItem: LnurlWithdrawSheetItem? {
        get {
            guard let config = activeSheetConfiguration, config.id == .lnurlWithdraw else { return nil }
            let lnurlWithdrawConfig = config.data as? LnurlWithdrawConfig
            let initialRoute = lnurlWithdrawConfig?.initialRoute ?? .amount
            return LnurlWithdrawSheetItem(initialRoute: initialRoute)
        }
        set {
            if newValue == nil {
                activeSheetConfiguration = nil
            }
        }
    }

    var notificationsSheetItem: NotificationsSheetItem? {
        get {
            guard let config = activeSheetConfiguration, config.id == .notifications else { return nil }
            return NotificationsSheetItem()
        }
        set {
            if newValue == nil {
                activeSheetConfiguration = nil
            }
        }
    }

    var quickpaySheetItem: QuickpaySheetItem? {
        get {
            guard let config = activeSheetConfiguration, config.id == .quickpay else { return nil }
            return QuickpaySheetItem()
        }
        set {
            if newValue == nil {
                activeSheetConfiguration = nil
            }
        }
    }

    var receiveSheetItem: ReceiveSheetItem? {
        get {
            guard let config = activeSheetConfiguration, config.id == .receive else { return nil }
            return ReceiveSheetItem()
        }
        set {
            if newValue == nil {
                activeSheetConfiguration = nil
            }
        }
    }

    var receivedTxSheetItem: ReceivedTxSheetItem? {
        get {
            guard let config = activeSheetConfiguration, config.id == .receivedTx else { return nil }
            let receivedTxConfig = config.data as? ReceivedTxSheetDetails
            guard let details = receivedTxConfig else { return nil }
            return ReceivedTxSheetItem(details: details)
        }
        set {
            if newValue == nil {
                activeSheetConfiguration = nil
            }
        }
    }

    var scannerSheetItem: ScannerSheetItem? {
        get {
            guard let config = activeSheetConfiguration, config.id == .scanner else { return nil }
            return ScannerSheetItem()
        }
        set {
            if newValue == nil {
                activeSheetConfiguration = nil
            }
        }
    }

    var securitySheetItem: SecuritySheetItem? {
        get {
            guard let config = activeSheetConfiguration, config.id == .security else { return nil }
            let securityConfig = config.data as? SecurityConfig
            let showLaterButton = securityConfig?.showLaterButton ?? false
            return SecuritySheetItem(showLaterButton: showLaterButton)
        }
        set {
            if newValue == nil {
                activeSheetConfiguration = nil
            }
        }
    }

    var sendSheetItem: SendSheetItem? {
        get {
            guard let config = activeSheetConfiguration, config.id == .send else { return nil }
            let sendConfig = config.data as? SendConfig
            let initialRoute = sendConfig?.initialRoute ?? .options
            return SendSheetItem(initialRoute: initialRoute)
        }
        set {
            if newValue == nil {
                activeSheetConfiguration = nil
            }
        }
    }
}
