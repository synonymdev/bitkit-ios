//
//  ScannerView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import CodeScanner
import SwiftUI

struct ScannerView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var currency: CurrencyViewModel

    var body: some View {
        ZStack {
            // Full screen scanner
            CodeScannerView(codeTypes: [.qr], shouldVibrateOnSuccess: false) { response in
                if case .success(let result) = response {
                    handleScan(result.string)
                } else if case .failure(let error) = response {
                    Logger.error(error, context: "Failed to scan QR code")
                    app.toast(error)
                }
            }
            .edgesIgnoringSafeArea(.all)

            // Scanner UI overlay - only the scanning area, not controls
            ScannerUIOverlay(onPaste: handlePaste)
        }
        .navigationTitle(localizedString("other__qr_scan"))
        .navigationBarTitleDisplayMode(.inline)
        .sheetBackground()
    }

    func handleScan(_ uri: String) {
        Haptics.play(.scanSuccess)

        Task { @MainActor in
            do {
                try await app.handleScannedData(uri)
                navigateToSendView()
            } catch {
                Logger.error(error, context: "Failed to read data from QR")
                app.toast(error)
            }
        }
    }

    func handlePaste() async {
        guard let uri = UIPasteboard.general.string else {
            Logger.error("No data in clipboard")
            app.toast(type: .warning, title: "No data in clipboard", description: "")
            return
        }

        do {
            try await app.handleScannedData(uri)
            navigateToSendView()
        } catch {
            Logger.error(error, context: "Failed to read data from clipboard")
            app.toast(error)
        }
    }

    private func navigateToSendView() {
        // TODO: find a better place to reset send state
        app.resetSendState()

        // If nil then it's not an invoice we're dealing with
        if app.invoiceRequiresCustomAmount == true {
            sheets.showSheet(.send, data: SendConfig(view: .amount))
        } else if app.invoiceRequiresCustomAmount == false {
            let invoiceAmount = app.scannedLightningInvoice?.amountSatoshis ?? 0
            let quickpayAmountSats = currency.convert(fiatAmount: settings.quickpayAmount, from: "USD") ?? 0

            // Decide which view to show based on the quickpay settings
            if settings.enableQuickpay && quickpayAmountSats > 0 && invoiceAmount <= quickpayAmountSats {
                sheets.showSheet(.send, data: SendConfig(view: .quickpay))
            } else {
                sheets.showSheet(.send, data: SendConfig(view: .confirm))
            }
        }
    }
}

// Scanner UI Overlay component for reuse in both actual and preview versions
struct ScannerUIOverlay: View {
    var onPaste: () async -> Void

    var body: some View {
        ZStack {
            // Scanner overlay with blur
            ScannerOverlayView()
                .edgesIgnoringSafeArea(.all)

            // UI Elements
            VStack {
                Spacer()

                // Paste button
                CustomButton(
                    title: localizedString("other__qr_paste"),
                    variant: .tertiary,
                    icon: Image("clipboard-white")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20),
                    action: { await onPaste() }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 36)
            }
            .edgesIgnoringSafeArea(.all)
        }
    }
}

// Preview-friendly version of the scanner that uses an image instead of the actual camera
struct ScannerPreview: View {
    @EnvironmentObject private var app: AppViewModel

    var body: some View {
        ZStack {
            // Background image instead of camera
            Image("preview-scan")
                .resizable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .edgesIgnoringSafeArea(.all)

            // Scanner UI overlay
            ScannerUIOverlay(
                onPaste: {
                    // No-op for preview
                }
            )
        }
        .navigationBarTitle(localizedString("other__qr_scan"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// UIKit-based scanner overlay
struct ScannerOverlayView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = TransparentHoleView()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// Custom UIView with transparent hole
class TransparentHoleView: UIView {
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let holeLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let darkOverlayView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    private func setupLayers() {
        // Add blur view
        blurView.frame = bounds
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blurView.alpha = 0.9
        addSubview(blurView)

        // Add dark overlay
        darkOverlayView.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        darkOverlayView.frame = bounds
        darkOverlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blurView.contentView.addSubview(darkOverlayView)

        // Configure hole layer (will be cut out of blur)
        holeLayer.fillRule = .evenOdd
        blurView.layer.mask = holeLayer

        // Configure border layer (just for the border)
        borderLayer.fillColor = UIColor.clear.cgColor
        borderLayer.strokeColor = UIColor.white.withAlphaComponent(0.1).cgColor
        borderLayer.lineWidth = 2
        layer.addSublayer(borderLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blurView.frame = bounds

        // Calculate hole size
        let width = bounds.width
        let height = bounds.height

        let holeWidth = min(width - 36, width)
        let holeHeight = height * 0.75 // Make the height 65% of available space
        let holeX = (width - holeWidth) / 2
        let holeY = (height - holeHeight) / 2

        // Create path with hole
        let path = UIBezierPath(rect: bounds)
        let holePath = UIBezierPath(roundedRect: CGRect(x: holeX, y: holeY, width: holeWidth, height: holeHeight), cornerRadius: 12)
        path.append(holePath)
        path.usesEvenOddFillRule = true

        // Apply path to layers
        holeLayer.path = path.cgPath

        // Create border path
        let borderPath = UIBezierPath(roundedRect: CGRect(x: holeX, y: holeY, width: holeWidth, height: holeHeight), cornerRadius: 12)
        borderLayer.path = borderPath.cgPath
    }
}

#Preview {
    // Use the preview-friendly version for previews
    NavigationStack {
        ScannerPreview()
            .environmentObject(AppViewModel())
    }
    .preferredColorScheme(.dark)
}
