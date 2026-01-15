import SwiftUI

enum SheetID: String, CaseIterable {
    case addTag
    case appUpdate
    case backup
    case boost
    case connectionClosed
    case forceTransfer
    case forgotPin
    case gift
    case highBalance
    case lnurlAuth
    case lnurlWithdraw
    case notifications
    case quickpay
    case receive
    case receivedTx
    case scanner
    case security
    case send
    case sweepPrompt
    case tagFilter
    case dateRangeSelector
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

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self else { return }
                Logger.debug("Showing sheet \(id.rawValue) after delay", context: "SheetViewModel")
                activeSheetConfiguration = SheetConfiguration(id: id, data: data)
                playHaptics(for: id)

                // Notify timed sheet manager
                Task { @MainActor in
                    TimedSheetManager.shared.onSheetShown()
                }
            }
        } else {
            // If no sheet is open, show the new sheet immediately
            Logger.debug("Showing sheet \(id.rawValue)", context: "SheetViewModel")
            activeSheetConfiguration = SheetConfiguration(id: id, data: data)
            playHaptics(for: id)

            // Notify timed sheet manager
            Task { @MainActor in
                TimedSheetManager.shared.onSheetShown()
            }
        }
    }

    func hideSheet(reason: String? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        if let config = activeSheetConfiguration {
            let fallback = "\(URL(fileURLWithPath: file).lastPathComponent):\(line) \(function)"
            let reasonText = " reason: \(reason ?? fallback)"
            Logger.debug("Hiding sheet \(config.id.rawValue)\(reasonText)", context: "SheetViewModel")
        } else {
            let fallback = "\(URL(fileURLWithPath: file).lastPathComponent):\(line) \(function)"
            let reasonText = " reason: \(reason ?? fallback)"
            Logger.debug("hideSheet called with no active sheet\(reasonText)", context: "SheetViewModel")
        }
        activeSheetConfiguration = nil

        // Notify timed sheet manager
        Task { @MainActor in
            TimedSheetManager.shared.onSheetDismissed()
        }
    }

    func hideSheetIfActive(_ id: SheetID, reason: String? = nil, file: String = #file, function: String = #function, line: Int = #line) {
        guard activeSheetConfiguration?.id == id else {
            let fallback = "\(URL(fileURLWithPath: file).lastPathComponent):\(line) \(function)"
            let reasonText = " reason: \(reason ?? fallback)"
            let activeId = activeSheetConfiguration?.id.rawValue ?? "none"
            Logger.debug("hideSheetIfActive skipped for \(id.rawValue) (active: \(activeId))\(reasonText)", context: "SheetViewModel")
            return
        }
        hideSheet(reason: reason, file: file, function: function, line: line)
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

    var connectionClosedSheetItem: ConnectionClosedSheetItem? {
        get {
            guard let config = activeSheetConfiguration, config.id == .connectionClosed else { return nil }
            return ConnectionClosedSheetItem()
        }
        set {
            if newValue == nil {
                activeSheetConfiguration = nil
            }
        }
    }

    var forgotPinSheetItem: ForgotPinSheetItem? {
        get {
            guard let config = activeSheetConfiguration, config.id == .forgotPin else { return nil }
            return ForgotPinSheetItem()
        }
        set {
            if newValue == nil {
                activeSheetConfiguration = nil
            }
        }
    }

    var giftSheetItem: GiftSheetItem? {
        get {
            guard let config = activeSheetConfiguration, config.id == .gift else { return nil }
            let giftConfig = config.data as? GiftConfig
            guard let code = giftConfig?.code, let amount = giftConfig?.amount else { return nil }
            return GiftSheetItem(code: code, amount: amount)
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

    var lnurlAuthSheetItem: LnurlAuthSheetItem? {
        get {
            guard let config = activeSheetConfiguration, config.id == .lnurlAuth else { return nil }
            let lnurlAuthConfig = config.data as? LnurlAuthConfig
            guard let lnurl = lnurlAuthConfig?.lnurl, let authData = lnurlAuthConfig?.authData else { return nil }
            return LnurlAuthSheetItem(lnurl: lnurl, authData: authData)
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
            let receiveConfig = config.data as? ReceiveConfig
            let initialRoute = receiveConfig?.initialRoute ?? .qr(cjitInvoice: nil, tab: nil)
            return ReceiveSheetItem(initialRoute: initialRoute)
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

    var forceTransferSheetItem: ForceTransferSheetItem? {
        get {
            guard let config = activeSheetConfiguration, config.id == .forceTransfer else { return nil }
            return ForceTransferSheetItem()
        }
        set {
            if newValue == nil {
                activeSheetConfiguration = nil
            }
        }
    }

    var sweepPromptSheetItem: SweepPromptSheetItem? {
        get {
            guard let config = activeSheetConfiguration, config.id == .sweepPrompt else { return nil }
            return SweepPromptSheetItem()
        }
        set {
            if newValue == nil {
                activeSheetConfiguration = nil
            }
        }
    }
}
