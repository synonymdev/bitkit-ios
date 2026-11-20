import PhotosUI
import SwiftUI

enum ScannerContext {
    case addContact
    case main
    case send
    case electrum
}

@MainActor
class ScannerManager: ObservableObject {
    private let playScanSuccess: () -> Void
    private var app: AppViewModel?
    private var contactsManager: ContactsManager?
    private var currency: CurrencyViewModel?
    private var settings: SettingsViewModel?
    private var navigation: NavigationViewModel?
    private var pubkyProfile: PubkyProfileManager?
    private var sheets: SheetViewModel?
    private var wallet: WalletViewModel?
    private weak var hwWalletManager: HwWalletManager?
    private let nfcReader: NfcPaymentReading
    private var isHandlingScan = false
    /// Set while a Bluetooth request holds the scan lock. A QR code or NFC read the user starts takes the lock from it.
    private var nearbyScanID: UUID?
    /// Whether the last main scan opened a payment flow, so a Bluetooth read knows the request was taken.
    private var didOpenScanFlow = false

    init(
        nfcReader: NfcPaymentReading? = nil,
        playScanSuccess: @escaping () -> Void = { Haptics.play(.scanSuccess) }
    ) {
        self.nfcReader = nfcReader ?? NfcReader.shared
        self.playScanSuccess = playScanSuccess
    }

    /// Whether this device can read NFC tags; NFC controls are hidden otherwise.
    var isNfcReadingAvailable: Bool {
        nfcReader.isAvailable
    }

    func configure(
        app: AppViewModel,
        contactsManager: ContactsManager? = nil,
        currency: CurrencyViewModel? = nil,
        settings: SettingsViewModel? = nil,
        navigation: NavigationViewModel? = nil,
        pubkyProfile: PubkyProfileManager? = nil,
        sheets: SheetViewModel? = nil,
        wallet: WalletViewModel? = nil,
        hwWalletManager: HwWalletManager? = nil
    ) {
        self.app = app
        self.contactsManager = contactsManager
        self.currency = currency
        self.settings = settings
        self.navigation = navigation
        self.pubkyProfile = pubkyProfile
        self.sheets = sheets
        self.wallet = wallet
        self.hwWalletManager = hwWalletManager
    }

    func handleScan(_ uri: String, context: ScannerContext, isCurrent: () -> Bool = { true }) async {
        guard isCurrent(), beginUserScan() else { return }
        defer { isHandlingScan = false }

        await processScan(uri, context: context, isCurrent: isCurrent)
    }

    private func processScan(
        _ uri: String,
        context: ScannerContext,
        scope: ScanHandlingScope = .unrestricted,
        isCurrent: () -> Bool
    ) async {
        let uri = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uri.isEmpty else { return }

        switch context {
        case .addContact:
            playScanSuccess()
            handleAddContactScan(uri)
        case .main:
            playScanSuccess()
            await handleMainScan(uri, scope: scope, isCurrent: isCurrent)
        case .send:
            await processSendScan(uri, scope: scope, isCurrent: isCurrent) { _ in }
        case .electrum:
            playScanSuccess()
            await handleElectrumScan(uri)
        }
    }

    func handleScan(_ payload: QRCodePayload, context: ScannerContext, isCurrent: () -> Bool = { true }) async {
        guard let uri = payload.string else {
            showUnsupportedQRCodeError()
            return
        }
        await handleScan(uri, context: context, isCurrent: isCurrent)
    }

    private func handleAddContactScan(_ input: String) {
        navigation?.navigateBack()

        guard !handlePubkyRouteIfNeeded(input) else {
            return
        }

        navigation?.navigate(.addContact(publicKey: input))
    }

    private func handleMainScan(_ uri: String, scope: ScanHandlingScope = .unrestricted, isCurrent: () -> Bool) async {
        didOpenScanFlow = false
        guard let app else { return }

        do {
            if let route = try resolveUsdtPaymentRoute(input: uri) {
                guard app.contactPaymentContext == nil, wallet?.usdtWallet.isSendPresented == false else { return }
                let path = navigation?.path
                sheets?.hideSheetBeforePerforming(reason: "Scanner routed USDT payment") { [weak self] in
                    guard let self, app.contactPaymentContext == nil, wallet?.usdtWallet.isSendPresented == false,
                          navigation?.path == path else { return }
                    navigation?.navigate(route)
                }
                didOpenScanFlow = true
                return
            }
            if handlePubkyRouteIfNeeded(uri) {
                return
            }

            try await app.handleScannedData(
                uri,
                scope: scope,
                alternativeOnchainBalanceSats: hwWalletManager?.maximumFundingBalanceSats ?? 0,
                isCurrentScan: isCurrent
            )
            guard isCurrent(), shouldOpenPaymentFlow(for: uri) else { return }

            if let currency, let settings, let sheets {
                let presentationBefore = sheets.activeSheetConfiguration?.presentationID
                PaymentNavigationHelper.openPaymentSheet(
                    app: app,
                    currency: currency,
                    settings: settings,
                    sheetViewModel: sheets
                )
                // A refused request (e.g. an expired invoice) only shows a toast and opens no sheet.
                didOpenScanFlow = !app.didRejectScannedPayment &&
                    sheets.activeSheetConfiguration?.presentationID != presentationBefore
            }
        } catch {
            guard isCurrent(), !(error is CancellationError) else { return }
            Logger.error(error, context: "Failed to read data from QR")
            app.toast(
                type: .error,
                title: t("other__qr_error_header"),
                description: t("other__qr_error_text")
            )
        }
    }

    private func handlePubkyRouteIfNeeded(_ input: String, hiding sheetId: SheetID? = .scanner, reason: String = "Scanner routed pubky key") -> Bool {
        guard let navigation,
              let route = resolvePastedPubkyRoute(
                  input: input,
                  ownPublicKey: pubkyProfile?.publicKey,
                  contacts: contactsManager?.contacts ?? []
              )
        else {
            return false
        }

        if let sheetId {
            sheets?.hideSheetIfActive(sheetId, reason: reason)
        }
        navigation.navigate(route)
        if case let .contactDetail(publicKey) = route,
           let contactsManager,
           let wallet
        {
            Task {
                await contactsManager.refreshContactLink(publicKey: publicKey, wallet: wallet)
            }
        }
        return true
    }

    func handleSendScan(
        _ uri: String,
        scope: ScanHandlingScope = .unrestricted,
        isCurrent: () -> Bool = { true },
        completion: @escaping (SendRoute?) -> Void
    ) async {
        guard isCurrent(), beginUserScan() else { return }
        defer { isHandlingScan = false }

        await processSendScan(uri, scope: scope, isCurrent: isCurrent, completion: completion)
    }

    private func processSendScan(
        _ uri: String,
        scope: ScanHandlingScope = .unrestricted,
        isCurrent: () -> Bool = { true },
        completion: @escaping (SendRoute?) -> Void
    ) async {
        guard let app, let currency, let settings else {
            completion(nil)
            return
        }

        guard !PubkyAuthRequest.isProtocolURL(uri) else {
            app.toast(
                type: .error,
                title: t("other__qr_error_header"),
                description: t("other__qr_error_text")
            )
            completion(nil)
            return
        }

        playScanSuccess()

        do {
            if scope != .onchainPayments, case let .usdtPayment(recipient, amount)? = try resolveUsdtPaymentRoute(input: uri) {
                guard app.contactPaymentContext == nil, wallet?.usdtWallet.isSendPresented == false else {
                    completion(nil)
                    return
                }
                completion(.usdtAddress(recipient: recipient, amount: amount))
                return
            }
            if handlePubkyRouteIfNeeded(uri, hiding: .send, reason: "Send scanner routed pubky key") {
                completion(nil)
                return
            }

            try await app.handleScannedData(
                uri,
                scope: scope,
                alternativeOnchainBalanceSats: hwWalletManager?.maximumFundingBalanceSats ?? 0,
                sendPresentationID: sheets?.activeSheetConfiguration?.presentationID,
                isCurrentScan: isCurrent
            )
            guard isCurrent() else { return }
            guard shouldOpenPaymentFlow(for: uri) else {
                completion(nil)
                return
            }

            let route = PaymentNavigationHelper.appropriateSendRoute(
                app: app,
                currency: currency,
                settings: settings
            )
            if route == .confirm, app.scannedLightningInvoice == nil, let invoice = app.scannedOnchainInvoice {
                wallet?.prepareFixedAmountOnchainSend(amountSats: invoice.amountSatoshis)
            }

            completion(route)
        } catch {
            guard isCurrent(), !(error is CancellationError) else { return }
            Logger.error(error, context: "Failed to read data from QR")
            app.toast(
                type: .error,
                title: t("other__qr_error_header"),
                description: t("other__qr_error_text")
            )
            completion(nil)
        }
    }

    func handleSendScan(
        _ payload: QRCodePayload,
        scope: ScanHandlingScope = .unrestricted,
        isCurrent: () -> Bool = { true },
        completion: @escaping (SendRoute?) -> Void
    ) async {
        guard let uri = payload.string else {
            showUnsupportedQRCodeError()
            completion(nil)
            return
        }
        await handleSendScan(uri, scope: scope, isCurrent: isCurrent, completion: completion)
    }

    /// Reads a payment request over NFC and handles it exactly like a scanned QR code.
    /// The read holds the scan lock from the start, so a Bluetooth request can't route while the NFC sheet is up.
    func handleNfcRead(context: ScannerContext, isCurrent: () -> Bool = { true }) async {
        let isCurrentOrigin = originCheck()
        func isStillCurrent() -> Bool {
            isCurrent() && isCurrentOrigin()
        }
        guard isStillCurrent(), beginUserScan() else { return }
        defer { isHandlingScan = false }
        guard let uri = await readNfcPaymentRequest(), isStillCurrent() else { return }
        await processScan(uri, context: context, isCurrent: isStillCurrent)
    }

    /// Reads a payment request over NFC from the Send sheet and resolves it like a scanned QR code.
    func handleSendNfcRead(
        scope: ScanHandlingScope = .unrestricted,
        isCurrent: () -> Bool = { true },
        completion: @escaping (SendRoute?) -> Void
    ) async {
        let isCurrentOrigin = originCheck()
        func isStillCurrent() -> Bool {
            isCurrent() && isCurrentOrigin()
        }
        guard isStillCurrent(), beginUserScan() else {
            completion(nil)
            return
        }
        defer { isHandlingScan = false }
        guard let uri = await readNfcPaymentRequest(), isStillCurrent() else {
            completion(nil)
            return
        }
        await processSendScan(uri, scope: scope, isCurrent: isStillCurrent, completion: completion)
    }

    /// Covers `lnbcrt`, `lntbs` and amounts after the network.
    private nonisolated static let bolt11Prefixes = ["lnbc", "lntb", "lnsb"]

    /// Whether a request read over Bluetooth is accepted: a `bitcoin:` URI, a `lightning:` BOLT11 invoice or a USDT
    /// `ethereum:` request. Unlike a camera or NFC read, a Bluetooth request can come from any nearby device before the
    /// user picks it, so nothing that is resolved over the network before review is taken: LNURL and Lightning
    /// addresses, also as a unified URI's `lightning` part, are refused. So are sign-in, setup, withdraw and contact
    /// links, and BOLT12 offers, which the decoder does not read.
    nonisolated static func isNearbyPaymentRequest(_ uri: String) -> Bool {
        let lowercase = uri.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func isBolt11(_ value: Substring) -> Bool {
            bolt11Prefixes.contains { value.hasPrefix($0) }
        }
        if lowercase.hasPrefix("ethereum:") {
            return true
        }
        if lowercase.hasPrefix("lightning:") {
            return isBolt11(lowercase.dropFirst("lightning:".count))
        }
        guard lowercase.hasPrefix("bitcoin:") else { return false }
        let query = lowercase.split(separator: "?", maxSplits: 1).dropFirst().first ?? ""
        return query.split(separator: "&").allSatisfy { pair in
            !pair.hasPrefix("lightning=") || isBolt11(pair.dropFirst("lightning=".count))
        }
    }

    /// Handles a request read over Bluetooth. It always opens the normal review (QuickPay does not apply) and is
    /// limited to on-chain, BOLT11 Lightning and USDT requests.
    /// - Returns: false when the request was not taken (refused, or another scan is being handled), so the caller
    ///   can keep listening.
    @discardableResult
    func handleNearbyRequest(_ request: String, context: ScannerContext, isCurrent: () -> Bool = { true }) async -> Bool {
        guard app != nil, context == .main || context == .send else { return false }
        let uri = ScannedPaymentRequest.normalized(request)
        guard Self.isNearbyPaymentRequest(uri) else {
            showUnsupportedQRCodeError()
            return false
        }
        // A request arrives unprompted, so it must not open anything once the user has left the scanner or started
        // a scan of their own.
        let isCurrentOrigin = originCheck()
        guard isCurrent(), isCurrentOrigin(), let scanID = beginNearbyScan() else { return false }
        defer { endNearbyScan(scanID) }
        func isStillCurrent() -> Bool {
            nearbyScanID == scanID && isCurrent() && isCurrentOrigin()
        }
        if context == .send {
            var routed = false
            await processSendScan(uri, scope: .paymentRequests, isCurrent: isStillCurrent) { routed = $0 != nil }
            return routed
        }
        await processScan(uri, context: .main, scope: .paymentRequests, isCurrent: isStillCurrent)
        return nearbyScanID == scanID && didOpenScanFlow
    }

    /// Send-sheet variant of `handleNearbyRequest`.
    @discardableResult
    func handleSendNearbyRequest(
        _ request: String,
        scope: ScanHandlingScope = .unrestricted,
        isCurrent: () -> Bool = { true },
        completion: @escaping (SendRoute?) -> Void
    ) async -> Bool {
        let uri = ScannedPaymentRequest.normalized(request)
        guard app != nil, Self.isNearbyPaymentRequest(uri) else {
            showUnsupportedQRCodeError()
            completion(nil)
            return false
        }
        let isCurrentOrigin = originCheck()
        guard isCurrent(), isCurrentOrigin(), let scanID = beginNearbyScan() else { return false }
        defer { endNearbyScan(scanID) }
        func isStillCurrent() -> Bool {
            nearbyScanID == scanID && isCurrent() && isCurrentOrigin()
        }
        var routed = false
        await processSendScan(
            uri,
            scope: scope == .onchainPayments ? .onchainPayments : .paymentRequests,
            isCurrent: isStillCurrent
        ) { route in
            routed = route != nil
            completion(route)
        }
        return routed
    }

    /// Takes the scan lock for a QR code or NFC read the user started. A Bluetooth request still decoding gives it up.
    private func beginUserScan() -> Bool {
        if isHandlingScan {
            guard let nearbyScanID else { return false }
            app?.releaseQuickPaySuppression(nearbyScanID)
            self.nearbyScanID = nil
        }
        isHandlingScan = true
        return true
    }

    private func beginNearbyScan() -> UUID? {
        guard !isHandlingScan else { return nil }
        let scanID = UUID()
        isHandlingScan = true
        nearbyScanID = scanID
        // A Bluetooth request always opens the normal review. The suppression ends with the request or when a user
        // scan takes over.
        app?.suppressQuickPay(scanID)
        return scanID
    }

    private func endNearbyScan(_ scanID: UUID) {
        app?.releaseQuickPaySuppression(scanID)
        // A user scan that took the lock releases it itself.
        guard nearbyScanID == scanID else { return }
        nearbyScanID = nil
        isHandlingScan = false
    }

    private func readNfcPaymentRequest() async -> String? {
        do {
            let request = try await nfcReader.readPaymentRequest(alertMessage: t("other__nfc_alert"))
            return ScannedPaymentRequest.normalized(request)
        } catch let error as NfcReadError {
            Logger.warn("NFC read failed: \(error)", context: "ScannerManager")
            showNfcReadError(error)
            return nil
        } catch {
            Logger.error(error, context: "ScannerManager NFC read")
            app?.toast(error)
            return nil
        }
    }

    private func showNfcReadError(_ error: NfcReadError) {
        guard !error.isSilent, error != .busy else { return }
        app?.toast(type: .error, title: t("other__nfc_error_header"), description: error.message)
    }

    private func shouldOpenPaymentFlow(for uri: String) -> Bool {
        !SamRockSetupRequest.isProtocolURL(uri) && !PubkyAuthRequest.isProtocolURL(uri)
    }

    private func handleElectrumScan(_ uri: String) async {
        guard let settings else { return }
        let generation = settings.serverConnectionGeneration
        guard settings.isCurrentServerConnection(generation) else { return }
        let result = await settings.onElectrumScan(uri)
        guard settings.isCurrentServerConnection(generation) else { return }

        if let result {
            if result.success {
                app?.toast(
                    type: .success,
                    title: t("settings__es__server_updated_title"),
                    description: t("settings__es__server_updated_message", variables: ["host": result.host, "port": result.port]),
                    accessibilityIdentifier: "ElectrumUpdatedToast"
                )
            } else {
                app?.toast(
                    type: .warning,
                    title: t("settings__es__error_peer"),
                    description: result.errorMessage ?? t("settings__es__server_error_description"),
                    accessibilityIdentifier: "ElectrumErrorToast"
                )
            }
        } else {
            app?.toast(
                type: .error,
                title: t("settings__es__error_peer"),
                description: t("settings__es__error_invalid_http")
            )
        }

        navigation?.navigateBack()
    }

    func handlePaste(context: ScannerContext) async {
        guard let app else { return }

        guard let uri = UIPasteboard.general.string else {
            app.toast(
                type: .warning,
                title: t("wallet__send_clipboard_empty_title"),
                description: t("wallet__send_clipboard_empty_text")
            )
            return
        }

        let value = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = ClipboardPromptHistory().recordInspection(changeCount: UIPasteboard.general.changeCount, supportedValue: value)
        await handleScan(value, context: context)
    }

    func handleImageSelection(
        _ item: PhotosPickerItem?,
        context: ScannerContext,
        scope: ScanHandlingScope = .unrestricted,
        completion: @escaping (SendRoute?) -> Void = { _ in }
    ) async {
        guard let item else { return }
        await handleImageScan(context: context, scope: scope, decode: {
            try await QRCodeImageDecoder.decode(item)
        }, completion: completion)
    }

    func handleImageScan(
        context: ScannerContext,
        scope: ScanHandlingScope = .unrestricted,
        decode: () async throws -> QRCodePayload,
        completion: @escaping (SendRoute?) -> Void = { _ in }
    ) async {
        guard let app else { return }
        let presentationID = sheets?.activeSheetConfiguration?.presentationID
        let navigationPath = navigation?.path
        let inputGeneration = app.sendStateGeneration
        func isCurrentOrigin() -> Bool {
            !Task.isCancelled && sheets?.activeSheetConfiguration?.presentationID == presentationID &&
                navigation?.path == navigationPath
        }

        do {
            let payload = try await decode()
            guard isCurrentOrigin(), context != .send || app.sendStateGeneration == inputGeneration else { return }
            if context == .send {
                await handleSendScan(payload, scope: scope, isCurrent: isCurrentOrigin, completion: completion)
            } else {
                await handleScan(payload, context: context, isCurrent: isCurrentOrigin)
            }
        } catch {
            guard isCurrentOrigin(), context != .send || app.sendStateGeneration == inputGeneration,
                  !(error is CancellationError) else { return }
            switch error {
            case QRCodeImageDecoderError.invalidImage:
                app.toast(
                    type: .error,
                    title: t("common__error"),
                    description: t("other__qr_error_load_image")
                )
            case QRCodeImageDecoderError.noQRCode:
                app.toast(
                    type: .error,
                    title: t("other__qr_error_no_qr_title"),
                    description: t("other__qr_error_no_qr_description")
                )
            default:
                Logger.error(error, context: "Failed to process image")
                app.toast(
                    type: .error,
                    title: t("other__qr_error_detection_title"),
                    description: t("other__qr_error_detection_description")
                )
            }
        }
    }

    /// True while the sheet and navigation path shown when this is called are still shown, without having left them.
    private func originCheck() -> () -> Bool {
        let presentationID = sheets?.activeSheetConfiguration?.presentationID
        let pathGeneration = navigation?.pathGeneration
        return { [weak self] in
            !Task.isCancelled && self?.sheets?.activeSheetConfiguration?.presentationID == presentationID &&
                self?.navigation?.pathGeneration == pathGeneration
        }
    }

    private func showUnsupportedQRCodeError() {
        app?.toast(
            type: .error,
            title: t("other__qr_error_header"),
            description: t("other__qr_error_text")
        )
    }

    func handleManualEntry(
        _ value: String,
        context: ScannerContext,
        onSuccess: @MainActor () -> Void
    ) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await handleScan(trimmed, context: context)
        await MainActor.run {
            onSuccess()
        }
    }
}
