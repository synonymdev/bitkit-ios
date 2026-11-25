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
    /// Photos the user picked that are still loading or decoding, each with a check that turns false once its scanner
    /// visit ends. A nearby request waits until every photo is handled or its visit ends.
    private var pendingImageScans: [UUID: () -> Bool] = [:]

    private var isImageScanPending: Bool {
        pendingImageScans.values.contains { $0() }
    }

    /// Set while a Bluetooth request holds the scan lock. A QR code or NFC read the user starts takes the lock from it.
    private var nearbyScanID: UUID?
    /// Whether the last main scan opened a payment flow, so a Bluetooth read knows the request was taken.
    private var didOpenScanFlow = false
    /// Raised when the app locks, so a scan still decoding cannot open a payment behind the PIN screen or after it.
    private var lockGeneration = 0
    /// A sheet replacement a scan started that has not run yet, so a lock can cancel the route it would open.
    private var pendingRouteReplacement: Int?

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

        // A lookup can outlast a PIN lock; its result must not route, or choose QuickPay, after the unlock.
        let isBeforeLock = lockCheck()
        await processScan(uri, context: context, isCurrent: { isCurrent() && isBeforeLock() })
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
                let replacementBefore = sheets?.latestReplacementID
                sheets?.hideSheetBeforePerforming(reason: "Scanner routed USDT payment") { [weak self] in
                    guard let self, app.contactPaymentContext == nil, wallet?.usdtWallet.isSendPresented == false,
                          navigation?.path == path else { return }
                    navigation?.navigate(route)
                }
                recordRouteReplacement(since: replacementBefore)
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
                let replacementBefore = sheets.latestReplacementID
                PaymentNavigationHelper.openPaymentSheet(
                    app: app,
                    currency: currency,
                    settings: settings,
                    sheetViewModel: sheets
                )
                recordRouteReplacement(since: replacementBefore)
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

    /// Remembers the replacement a route started, so a lock before it runs drops it. Called right after the
    /// synchronous route call with the id read just before it, so a sheet that replaced the scanner while the scan
    /// was decoding (e.g. a received payment) is not claimed.
    private func recordRouteReplacement(since before: Int?) {
        guard let replacement = sheets?.latestReplacementID, replacement != before else { return }
        pendingRouteReplacement = replacement
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

        let isBeforeLock = lockCheck()
        await processSendScan(uri, scope: scope, isCurrent: { isCurrent() && isBeforeLock() }, completion: completion)
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
        guard let uri = await readNfcPaymentRequest(isCurrent: isStillCurrent), isStillCurrent() else { return }
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
        guard let uri = await readNfcPaymentRequest(isCurrent: isStillCurrent), isStillCurrent() else {
            completion(nil)
            return
        }
        await processSendScan(uri, scope: scope, isCurrent: isStillCurrent, completion: completion)
    }

    /// Whether a request read over Bluetooth is accepted: a `bitcoin:` URI, a `lightning:` BOLT11 invoice or a USDT
    /// `ethereum:` request. Unlike a camera or NFC read, a Bluetooth request can come from any nearby device before the
    /// user picks it, so nothing that is resolved over the network before review is taken: LNURL and Lightning
    /// addresses, also as a unified URI's `lightning` part, are refused. So are sign-in, setup, withdraw and contact
    /// links, and BOLT12 offers, which the decoder does not read. An invoice is checked locally
    /// (`ScannedPaymentRequest.isBolt11Invoice`), since a Lightning address can begin like one. A `bitcoin:` request
    /// with a required (`req-`) parameter is refused, since none is supported.
    nonisolated static func isNearbyPaymentRequest(_ uri: String) -> Bool {
        typealias Request = ScannedPaymentRequest
        let lowercase = uri.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if Request.hasLiteralPrefix(lowercase, "ethereum:") {
            return true
        }
        if Request.hasLiteralPrefix(lowercase, "lightning:") {
            return Request.isBolt11Invoice(Request.droppingLiteralPrefix(lowercase, "lightning:"))
        }
        guard Request.hasLiteralPrefix(lowercase, "bitcoin:"), !Request.hasRequiredParameter(lowercase) else { return false }
        // Split as the decoder splits, so a delimiter followed by a combining mark still separates the fields.
        return Request.queryFields(lowercase).allSatisfy { field in
            !Request.hasLiteralPrefix(field, "lightning=") || Request.isBolt11Invoice(Request.droppingLiteralPrefix(field, "lightning="))
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
            if isCurrent() {
                showUnsupportedQRCodeError()
            }
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
            if isCurrent() {
                showUnsupportedQRCodeError()
            }
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
        guard !isHandlingScan, !isImageScanPending else { return nil }
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

    /// Reads a payment request over NFC. A failure shows its error only while [isCurrent] holds: a read that ends after
    /// the payer left the scanner, or the app locked, ends quietly.
    private func readNfcPaymentRequest(isCurrent: () -> Bool) async -> String? {
        do {
            let request = try await nfcReader.readPaymentRequest(alertMessage: t("other__nfc_alert"))
            let uri = ScannedPaymentRequest.normalized(request)
            // A QR code with a required parameter still goes to the decoder; core handles those after its bump (#1344).
            guard !ScannedPaymentRequest.hasRequiredParameter(uri) else { throw NfcReadError.noPaymentRequest }
            return uri
        } catch let error as NfcReadError {
            Logger.warn("NFC read failed: \(error)", context: "ScannerManager")
            if isCurrent() {
                showNfcReadError(error)
            }
            return nil
        } catch {
            Logger.error(error, context: "ScannerManager NFC read")
            if isCurrent() {
                app?.toast(error)
            }
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
        isCurrent: @escaping () -> Bool = { true },
        scope: ScanHandlingScope = .unrestricted,
        completion: @escaping (SendRoute?) -> Void = { _ in }
    ) async {
        guard let item else { return }
        await handleImageScan(context: context, isCurrent: isCurrent, scope: scope, decode: {
            try await QRCodeImageDecoder.decode(item)
        }, completion: completion)
    }

    func handleImageScan(
        context: ScannerContext,
        isCurrent: @escaping () -> Bool = { true },
        scope: ScanHandlingScope = .unrestricted,
        decode: () async throws -> QRCodePayload,
        completion: @escaping (SendRoute?) -> Void = { _ in }
    ) async {
        guard let app else { return }
        let inputGeneration = app.sendStateGeneration
        // One check for the scanner visit the photo was picked in, used both to hold off nearby requests and to route
        // the photo: the sheet, the navigation path generation (leaving and reopening a route is a new visit) and the
        // caller's own visit, such as Send Options' inside its sheet.
        let isOriginShown = originCheck()
        let isCurrentOrigin = { isCurrent() && isOriginShown() }

        do {
            let payload = try await decodeBeforeNearbyRequests(decode, isCurrent: isCurrentOrigin)
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

    /// Loads and decodes a picked photo. Like the user's other scans, the photo takes over a nearby request still
    /// decoding, and it holds off new ones, since either would open Send and discard the photo.
    private func decodeBeforeNearbyRequests(
        _ decode: () async throws -> QRCodePayload,
        isCurrent: @escaping () -> Bool
    ) async throws -> QRCodePayload {
        if let nearbyScanID {
            app?.releaseQuickPaySuppression(nearbyScanID)
            self.nearbyScanID = nil
            isHandlingScan = false
        }
        let id = UUID()
        pendingImageScans[id] = isCurrent
        defer { pendingImageScans[id] = nil }
        return try await decode()
    }

    /// True until the app locks behind the PIN after this call.
    private func lockCheck() -> () -> Bool {
        let lockGeneration = lockGeneration
        return { [weak self] in
            self?.lockGeneration == lockGeneration
        }
    }

    /// True while the sheet and navigation path shown when this is called are still shown, without having left them.
    private func originCheck() -> () -> Bool {
        let presentationID = sheets?.activeSheetConfiguration?.presentationID
        let pathGeneration = navigation?.pathGeneration
        let lockGeneration = lockGeneration
        return { [weak self] in
            !Task.isCancelled && self?.sheets?.activeSheetConfiguration?.presentationID == presentationID &&
                self?.navigation?.pathGeneration == pathGeneration && self?.lockGeneration == lockGeneration
        }
    }

    /// Drops every scan still being handled, and a route a scan opens once its sheet has closed. Called when the app
    /// locks behind the PIN.
    func invalidateScansForAppLock() {
        lockGeneration += 1
        if let replacement = pendingRouteReplacement {
            sheets?.cancelReplacement(replacement)
            pendingRouteReplacement = nil
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
