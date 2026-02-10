import SwiftUI

struct ProbingToolScannerSheet: View {
    @Binding var invoice: String
    @Environment(\.dismiss) private var dismiss
    let onScanned: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("other__qr_scan"))

            VStack(alignment: .leading, spacing: 0) {
                Scanner(
                    onScan: { uri in
                        await MainActor.run {
                            invoice = uri.trimmingCharacters(in: .whitespacesAndNewlines)
                            onScanned()
                            dismiss()
                        }
                    },
                    onImageSelection: { _ in
                        // Optional: could decode image and set invoice if needed
                    }
                )
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }
}
