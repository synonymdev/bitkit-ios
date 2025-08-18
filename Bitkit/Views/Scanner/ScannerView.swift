import CodeScanner
import PhotosUI
import SwiftUI
import Vision

let headerHeight: CGFloat = 60
let buttonHeight: CGFloat = 56
let spacing: CGFloat = 16
let headerSpace = headerHeight + spacing
let buttonSpace = buttonHeight + spacing

struct ScannerView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    var showBackButton: Bool = false

    @State private var isFlashlightOn = false
    @State private var selectedItem: PhotosPickerItem?

    var body: some View {
        ZStack {
            // Full screen scanner
            CodeScannerView(codeTypes: [.qr], shouldVibrateOnSuccess: false, isTorchOn: isFlashlightOn) { response in
                if case let .success(result) = response {
                    handleScan(result.string)
                } else if case let .failure(error) = response {
                    Logger.error(error, context: "Failed to scan QR code")
                    app.toast(error)
                }
            }

            // Sheet background with hole
            GeometryReader { geometry in
                let availableHeight = geometry.size.height - headerSpace - buttonSpace

                Rectangle()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.white.opacity(0.08), Color.white.opacity(0.012)]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .background(Color.black)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .frame(
                                width: geometry.size.width - spacing * 2,
                                height: availableHeight
                            )
                            .position(
                                x: geometry.size.width / 2,
                                y: headerSpace + availableHeight / 2
                            )
                            .blendMode(.destinationOut)
                    )
                    .edgesIgnoringSafeArea(.all)
            }

            // UI Elements on top of camera
            VStack {
                SheetHeader(title: t("other__qr_scan"), showBackButton: showBackButton)

                Spacer()

                CustomButton(
                    title: t("other__qr_paste"),
                    icon: Image("clipboard")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16),
                ) {
                    await handlePaste()
                }
            }
            .padding(.horizontal, 16)

            // Corner buttons
            GeometryReader { _ in
                HStack {
                    PhotosPicker(selection: $selectedItem, matching: .images) {
                        Image("picture")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 24, height: 24)
                            .foregroundColor(.white)
                            .frame(width: 48, height: 48)
                            .background(Color.white16)
                            .clipShape(Circle())
                    }
                    .onChange(of: selectedItem) { item in
                        Task {
                            await handleImageSelection(item)
                        }
                    }

                    Spacer()

                    IconButton(icon: Image("flashlight")) {
                        isFlashlightOn.toggle()
                    }
                    .background(isFlashlightOn ? Color.white32 : Color.clear)
                    .clipShape(Circle())
                }
                .padding(.top, headerSpace + spacing)
                .padding(.horizontal, spacing * 2)
            }
        }
        .navigationBarHidden(true)
    }

    func handleScan(_ uri: String) {
        Haptics.play(.scanSuccess)

        Task { @MainActor in
            do {
                try await app.handleScannedData(uri)
                PaymentNavigationHelper.openPaymentSheet(
                    app: app,
                    currency: currency,
                    settings: settings,
                    sheetViewModel: sheets
                )
            } catch {
                Logger.error(error, context: "Failed to read data from QR")
                app.toast(
                    type: .error,
                    title: t("other__qr_error_header"),
                    description: t("other__qr_error_text")
                )
            }
        }
    }

    func handlePaste() async {
        guard let uri = UIPasteboard.general.string else {
            app.toast(
                type: .warning,
                title: t("wallet__send_clipboard_empty_title"),
                description: t("wallet__send_clipboard_empty_text")
            )
            return
        }

        handleScan(uri)
    }

    func handleImageSelection(_ item: PhotosPickerItem?) async {
        guard let item else { return }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else {
                app.toast(
                    type: .error,
                    title: "Error",
                    description: "Sorry. Bitkit wasn't able to load this image."
                )
                return
            }

            // Detect QR codes in the image
            guard let cgImage = image.cgImage else {
                app.toast(
                    type: .error,
                    title: "Error",
                    description: "Sorry. Bitkit wasn't able to process this image."
                )
                return
            }

            let request = VNDetectBarcodesRequest { request, error in
                if let error {
                    Logger.error(error, context: "QR detection failed")
                    DispatchQueue.main.async {
                        app.toast(
                            type: .error,
                            title: "Detection Error",
                            description: "Failed to process the image for QR codes."
                        )
                    }
                    return
                }

                guard let results = request.results as? [VNBarcodeObservation] else {
                    Logger.error("No barcode results found")
                    DispatchQueue.main.async {
                        app.toast(
                            type: .error,
                            title: "No QR Code Found",
                            description: "Sorry. Bitkit wasn't able to detect a QR code in this image."
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
                            title: "No QR Code Found",
                            description: "Sorry. Bitkit wasn't able to detect a QR code in this image."
                        )
                    }
                    return
                }

                DispatchQueue.main.async {
                    handleScan(payload)
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
                title: "Error",
                description: "Sorry. An error occurred when trying to process this image."
            )
        }

        selectedItem = nil
    }
}
