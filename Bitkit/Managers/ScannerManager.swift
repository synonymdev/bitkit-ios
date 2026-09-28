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
    private var app: AppViewModel?
    private var contactsManager: ContactsManager?
    private var currency: CurrencyViewModel?
    private var settings: SettingsViewModel?
    private var navigation: NavigationViewModel?
    private var pubkyProfile: PubkyProfileManager?
    private var sheets: SheetViewModel?
    private var wallet: WalletViewModel?
    private weak var hwWalletManager: HwWalletManager?
    private var isHandlingScan = false

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

    func handleScan(_ uri: String, context: ScannerContext) async {
        guard !isHandlingScan else { return }
        isHandlingScan = true
        defer { isHandlingScan = false }

        await processScan(uri, context: context)
    }

    private func processScan(_ uri: String, context: ScannerContext) async {
        let uri = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uri.isEmpty else { return }

        Haptics.play(.scanSuccess)

        switch context {
        case .addContact:
            handleAddContactScan(uri)
        case .main:
            await handleMainScan(uri)
        case .send:
            await processSendScan(uri) { _ in }
        case .electrum:
            await handleElectrumScan(uri)
        }
    }

    func handleScan(_ payload: QRCodePayload, context: ScannerContext) async {
        guard let uri = payload.string else {
            showUnsupportedQRCodeError()
            return
        }
        await handleScan(uri, context: context)
    }

    private func handleAddContactScan(_ input: String) {
        navigation?.navigateBack()

        guard !handlePubkyRouteIfNeeded(input) else {
            return
        }

        navigation?.navigate(.addContact(publicKey: input))
    }

    private func handleMainScan(_ uri: String) async {
        guard let app else { return }

        do {
            if handlePubkyRouteIfNeeded(uri) {
                return
            }

            try await app.handleScannedData(
                uri,
                alternativeOnchainBalanceSats: hwWalletManager?.maximumFundingBalanceSats ?? 0
            )
            guard shouldOpenPaymentFlow(for: uri) else { return }

            if let currency, let settings, let sheets {
                PaymentNavigationHelper.openPaymentSheet(
                    app: app,
                    currency: currency,
                    settings: settings,
                    sheetViewModel: sheets
                )
            }
        } catch {
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
                await contactsManager.refreshContactReceiverPaths(publicKey: publicKey, wallet: wallet)
            }
        }
        return true
    }

    func handleSendScan(
        _ uri: String,
        scope: ScanHandlingScope = .unrestricted,
        completion: @escaping (SendRoute?) -> Void
    ) async {
        guard !isHandlingScan else { return }
        isHandlingScan = true
        defer { isHandlingScan = false }

        await processSendScan(uri, scope: scope, completion: completion)
    }

    private func processSendScan(
        _ uri: String,
        scope: ScanHandlingScope = .unrestricted,
        completion: @escaping (SendRoute?) -> Void
    ) async {
        guard let app, let currency, let settings else {
            completion(nil)
            return
        }

        Haptics.play(.scanSuccess)

        guard !PubkyAuthRequest.isProtocolURL(uri) else {
            app.toast(
                type: .error,
                title: t("other__qr_error_header"),
                description: t("other__qr_error_text")
            )
            completion(nil)
            return
        }

        do {
            if handlePubkyRouteIfNeeded(uri, hiding: .send, reason: "Send scanner routed pubky key") {
                completion(nil)
                return
            }

            try await app.handleScannedData(
                uri,
                scope: scope,
                alternativeOnchainBalanceSats: hwWalletManager?.maximumFundingBalanceSats ?? 0
            )
            guard shouldOpenPaymentFlow(for: uri) else {
                completion(nil)
                return
            }

            let route = PaymentNavigationHelper.appropriateSendRoute(
                app: app,
                currency: currency,
                settings: settings
            )

            completion(route)
        } catch {
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
        completion: @escaping (SendRoute?) -> Void
    ) async {
        guard let uri = payload.string else {
            showUnsupportedQRCodeError()
            completion(nil)
            return
        }
        await handleSendScan(uri, scope: scope, completion: completion)
    }

    private func shouldOpenPaymentFlow(for uri: String) -> Bool {
        !SamRockSetupRequest.isProtocolURL(uri) && !PubkyAuthRequest.isProtocolURL(uri)
    }

    private func handleElectrumScan(_ uri: String) async {
        guard let settings else { return }

        if let result = await settings.onElectrumScan(uri) {
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

        await handleScan(uri.trimmingCharacters(in: .whitespacesAndNewlines), context: context)
    }

    func handleImageSelection(
        _ item: PhotosPickerItem?,
        context: ScannerContext,
        scope: ScanHandlingScope = .unrestricted,
        completion: @escaping (SendRoute?) -> Void = { _ in }
    ) async {
        guard let app, let item else { return }

        do {
            let payload = try await QRCodeImageDecoder.decode(item)
            if context == .send {
                await handleSendScan(payload, scope: scope, completion: completion)
            } else {
                await handleScan(payload, context: context)
            }
        } catch QRCodeImageDecoderError.invalidImage {
            app.toast(
                type: .error,
                title: t("common__error"),
                description: t("other__qr_error_load_image")
            )
        } catch QRCodeImageDecoderError.noQRCode {
            app.toast(
                type: .error,
                title: t("other__qr_error_no_qr_title"),
                description: t("other__qr_error_no_qr_description")
            )
        } catch {
            Logger.error(error, context: "Failed to process image")
            app.toast(
                type: .error,
                title: t("other__qr_error_detection_title"),
                description: t("other__qr_error_detection_description")
            )
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
