import PhotosUI
import SwiftUI
import Vision

enum ScannerContext {
    case main
    case send
    case electrum
}

@MainActor
class ScannerManager: ObservableObject {
    private var app: AppViewModel?
    private var wallet: WalletViewModel?
    private var currency: CurrencyViewModel?
    private var settings: SettingsViewModel?
    private var navigation: NavigationViewModel?
    private var sheets: SheetViewModel?

    private static let nodeReadyDelayNanoseconds: UInt64 = 500_000_000

    func configure(
        app: AppViewModel,
        wallet: WalletViewModel? = nil,
        currency: CurrencyViewModel? = nil,
        settings: SettingsViewModel? = nil,
        navigation: NavigationViewModel? = nil,
        sheets: SheetViewModel? = nil
    ) {
        self.app = app
        self.wallet = wallet
        self.currency = currency
        self.settings = settings
        self.navigation = navigation
        self.sheets = sheets
    }

    func handleScan(_ uri: String, context: ScannerContext) async {
        Haptics.play(.scanSuccess)

        switch context {
        case .main:
            await handleMainScan(uri)
        case .send:
            await handleSendScan(uri) { _ in }
        case .electrum:
            await handleElectrumScan(uri)
        }
    }

    private func handleMainScan(_ uri: String) async {
        guard let app else { return }

        do {
            if let wallet {
                _ = await wallet.waitForNodeToRun()
                try? await Task.sleep(nanoseconds: Self.nodeReadyDelayNanoseconds)
            }

            try await app.handleScannedData(uri)

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

    func handleSendScan(_ uri: String, completion: @escaping (SendRoute?) -> Void) async {
        guard let app, let currency, let settings else {
            completion(nil)
            return
        }

        Haptics.play(.scanSuccess)

        do {
            if let wallet {
                _ = await wallet.waitForNodeToRun()
                try? await Task.sleep(nanoseconds: Self.nodeReadyDelayNanoseconds)
            }

            try await app.handleScannedData(uri)

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

        await handleScan(uri, context: context)
    }

    func handleImageSelection(_ item: PhotosPickerItem?, context: ScannerContext, completion: @escaping (SendRoute?) -> Void = { _ in }) async {
        guard let app, let item else { return }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else {
                app.toast(
                    type: .error,
                    title: "Error",
                    description: tTodo("Sorry. Bitkit wasn't able to load this image.")
                )
                return
            }

            guard let cgImage = image.cgImage else {
                app.toast(
                    type: .error,
                    title: "Error",
                    description: tTodo("Sorry. Bitkit wasn't able to process this image.")
                )
                return
            }

            let request = VNDetectBarcodesRequest { [weak self] request, error in
                if let error {
                    Logger.error(error, context: "QR detection failed")
                    DispatchQueue.main.async {
                        app.toast(
                            type: .error,
                            title: tTodo("Detection Error"),
                            description: tTodo("Failed to process the image for QR codes.")
                        )
                    }
                    return
                }

                guard let results = request.results as? [VNBarcodeObservation] else {
                    Logger.error("No barcode results found")
                    DispatchQueue.main.async {
                        app.toast(
                            type: .error,
                            title: tTodo("No QR Code Found"),
                            description: tTodo("Sorry. Bitkit wasn't able to detect a QR code in this image.")
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
                            title: tTodo("No QR Code Found"),
                            description: tTodo("Sorry. Bitkit wasn't able to detect a QR code in this image.")
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
                if #available(iOS 16, *) {
                    request.revision = VNDetectBarcodesRequestRevision1
                }
            #endif

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])
        } catch {
            Logger.error(error, context: "Failed to process image")
            app.toast(
                type: .error,
                title: tTodo("Error"),
                description: tTodo("Sorry. An error occurred when trying to process this image.")
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
