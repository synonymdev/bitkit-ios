import CoreImage.CIFilterBuiltins
import SwiftUI

struct QrArea: View {
    let uri: String
    let imageAsset: String?
    let accentColor: Color
    @Binding var navigationPath: [ReceiveRoute]

    @State private var showCopyTooltip = false
    @State private var showShareSheet = false
    @State private var shareQRImage: UIImage?

    private var shareItems: [Any] {
        // If image is not available, generate it on-demand
        let image = shareQRImage ?? generateShareQrImage()
        return [uri, image ?? UIImage()]
    }

    var body: some View {
        ZStack {
            QR(content: uri, imageAsset: imageAsset)

            if showCopyTooltip {
                Tooltip(text: t("wallet__receive_copied"))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .offset(y: 80)
                    .allowsHitTesting(false)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showCopyTooltip)
            }
        }

        HStack {
            CustomButton(
                title: t("common__edit"),
                size: .small,
                icon: Image("pencil").foregroundColor(accentColor),
                shouldExpand: true
            ) {
                navigationPath.append(.edit)
            }

            CustomButton(
                title: t("common__copy"),
                size: .small,
                icon: Image("copy").foregroundColor(accentColor),
                shouldExpand: true
            ) {
                onCopy()
            }

            CustomButton(
                title: t("common__share"),
                size: .small,
                icon: Image("share").foregroundColor(accentColor),
                shouldExpand: true
            ) {
                showShareSheet = true
            }
        }
        .padding(.vertical)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: shareItems)
        }
        .onAppear {
            // Pre-generate the QR image for sharing
            shareQRImage = generateShareQrImage()
        }
        .onChange(of: uri) { _ in
            // Regenerate when URI changes
            shareQRImage = generateShareQrImage()
        }
    }

    private func generateShareQrImage() -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(uri.utf8)

        if let outputImage = filter.outputImage {
            // Generate padded QR image for sharing
            let fixedSize = 400
            let padding: CGFloat = 16
            let qrSize = CGFloat(fixedSize) - (padding * 2)

            // Scale the QR code to fit exactly in the available space
            let scale = qrSize / outputImage.extent.width
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            let scaledOutputImage = outputImage.transformed(by: transform)

            if let cgImage = context.createCGImage(scaledOutputImage, from: scaledOutputImage.extent) {
                UIGraphicsBeginImageContextWithOptions(CGSize(width: fixedSize, height: fixedSize), false, 0)
                defer { UIGraphicsEndImageContext() }

                // Fill background with white
                UIColor.white.setFill()
                UIRectFill(CGRect(origin: .zero, size: CGSize(width: fixedSize, height: fixedSize)))

                // Calculate position to center the QR code with padding
                let qrRect = CGRect(
                    x: padding,
                    y: padding,
                    width: qrSize,
                    height: qrSize
                )

                // Draw the QR code in the padded area
                UIImage(cgImage: cgImage).draw(in: qrRect)

                let generatedImage = UIGraphicsGetImageFromCurrentImageContext()
                return generatedImage
            }
        }

        return nil
    }

    private func onCopy() {
        UIPasteboard.general.string = uri
        Haptics.play(.copiedToClipboard)

        // Show tooltip
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            showCopyTooltip = true
        }

        // Hide tooltip after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                showCopyTooltip = false
            }
        }
    }
}
