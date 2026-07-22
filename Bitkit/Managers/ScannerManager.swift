import PhotosUI
import SwiftUI
import Vision

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

    func configure(
        app: AppViewModel,
        contactsManager: ContactsManager? = nil,
        currency: CurrencyViewModel? = nil,
        settings: SettingsViewModel? = nil,
        navigation: NavigationViewModel? = nil,
        pubkyProfile: PubkyProfileManager? = nil,
        sheets: SheetViewModel? = nil,
        wallet: WalletViewModel? = nil
    ) {
        self.app = app
        self.contactsManager = contactsManager
        self.currency = currency
        self.settings = settings
        self.navigation = navigation
        self.pubkyProfile = pubkyProfile
        self.sheets = sheets
        self.wallet = wallet
    }

    func handleScan(_ uri: String, context: ScannerContext) async {
        let uri = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uri.isEmpty else { return }

        Haptics.play(.scanSuccess)

        switch context {
        case .addContact:
            handleAddContactScan(uri)
        case .main:
            await handleMainScan(uri)
        case .send:
            await handleSendScan(uri) { _ in }
        case .electrum:
            await handleElectrumScan(uri)
        }
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

            try await app.handleScannedData(uri)
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

    func handleSendScan(_ uri: String, completion: @escaping (SendRoute?) -> Void) async {
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

            try await app.handleScannedData(uri)
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

    func handleImageSelection(_ item: PhotosPickerItem?, context: ScannerContext, completion: @escaping (SendRoute?) -> Void = { _ in }) async {
        guard let app, let item else { return }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else {
                app.toast(
                    type: .error,
                    title: t("common__error"),
                    description: t("other__qr_error_load_image")
                )
                return
            }

            guard let cgImage = image.cgImage else {
                app.toast(
                    type: .error,
                    title: t("common__error"),
                    description: t("other__qr_error_process_image")
                )
                return
            }

            let request = VNDetectBarcodesRequest { [weak self] request, error in
                if let error {
                    Logger.error(error, context: "QR detection failed")
                    DispatchQueue.main.async {
                        app.toast(
                            type: .error,
                            title: t("other__qr_error_detection_title"),
                            description: t("other__qr_error_detection_description")
                        )
                    }
                    return
                }

                guard let results = request.results as? [VNBarcodeObservation] else {
                    Logger.error("No barcode results found")
                    DispatchQueue.main.async {
                        app.toast(
                            type: .error,
                            title: t("other__qr_error_no_qr_title"),
                            description: t("other__qr_error_no_qr_description")
                        )
                    }
                    return
                }

                let qrResults = results.filter { $0.symbology == .qr }

                guard let firstResult = qrResults.first,
                      let payload = firstResult.payloadStringValue
                else {
                    DispatchQueue.main.async {
                        app.toast(
                            type: .error,
                            title: t("other__qr_error_no_qr_title"),
                            description: t("other__qr_error_no_qr_description")
                        )
                    }
                    return
                }

                DispatchQueue.main.async {
                    if context == .send {
                        Task {
                            await self?.handleSendScan(payload, completion: completion)
                        }
                    } else {
                        Task {
                            await self?.handleScan(payload, context: context)
                        }
                    }
                }
            }

            #if targetEnvironment(simulator) && compiler(>=5.7)
                request.revision = VNDetectBarcodesRequestRevision3
            #endif

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])
        } catch {
            Logger.error(error, context: "Failed to process image")
            app.toast(
                type: .error,
                title: t("common__error"),
                description: t("other__qr_error_generic_description")
            )
        }
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
