import SwiftUI

struct QrArea: View {
    let uri: String
    let imageAsset: String?
    let accentColor: Color
    var copyValue: String?
    var shareText: String?
    var onEdit: (() -> Void)?

    @State private var showCopyTooltip = false
    @State private var showShareSheet = false
    @State private var shareQRImage: UIImage?

    private var shareItems: [Any] {
        // If image is not available, generate it on-demand
        let image = shareQRImage ?? QR.shareImage(content: uri)
        return [shareText ?? uri, image ?? UIImage()]
    }

    var body: some View {
        ZStack {
            if uri.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                QR(content: uri, imageAsset: imageAsset) { onCopy() }
            }

            if showCopyTooltip {
                Tooltip(text: t("wallet__receive_copied"))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .offset(y: 80)
                    .allowsHitTesting(false)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showCopyTooltip)
            }
        }

        HStack {
            if let onEdit {
                CustomButton(
                    title: t("common__edit"),
                    size: .small,
                    icon: Image("pencil").foregroundColor(accentColor),
                    shouldExpand: true,
                    action: onEdit
                )
                .accessibilityIdentifier("SpecifyInvoiceButton")
            }

            CustomButton(
                title: t("common__copy"),
                size: .small,
                icon: Image("copy").foregroundColor(accentColor),
                isDisabled: uri.isEmpty,
                shouldExpand: true
            ) {
                onCopy()
            }
            .accessibilityIdentifier("ReceiveCopyQR")

            CustomButton(
                title: t("common__share"),
                size: .small,
                icon: Image("share").foregroundColor(accentColor),
                isDisabled: uri.isEmpty,
                shouldExpand: true
            ) {
                showShareSheet = true
            }
        }
        .padding(.vertical)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(activityItems: shareItems)
        }
        .onChange(of: uri, initial: true) {
            // Generate the QR image for sharing
            shareQRImage = QR.shareImage(content: uri)
        }
    }

    private func onCopy() {
        UIPasteboard.general.string = copyValue ?? uri
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
