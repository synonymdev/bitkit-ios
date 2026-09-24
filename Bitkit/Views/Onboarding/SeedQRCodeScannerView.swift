import PhotosUI
import SwiftUI

struct SeedQRCodeScannerView: View {
    @EnvironmentObject private var app: AppViewModel
    @Environment(\.dismiss) private var dismiss

    let onScan: (String) -> Void

    var body: some View {
        Scanner(
            onScan: { payload in
                handlePayload(payload)
            },
            onImageSelection: { item in
                await handleImageSelection(item)
            }
        )
        .screenshotPreventMask(true)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .navigationTitle(t("onboarding__restore_scan_seedqr"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func handleImageSelection(_ item: PhotosPickerItem?) async {
        guard let item else { return }

        do {
            let payload = try await QRCodeImageDecoder.decode(item)
            await MainActor.run {
                handlePayload(payload)
            }
        } catch {
            await MainActor.run {
                showInvalidSeedQRError()
            }
        }
    }

    private func handlePayload(_ payload: QRCodePayload) {
        do {
            let mnemonic = try SeedQRCodeDecoder.decode(payload)
            Haptics.play(.scanSuccess)
            onScan(mnemonic)
            dismiss()
        } catch {
            showInvalidSeedQRError()
        }
    }

    private func showInvalidSeedQRError() {
        app.toast(
            type: .error,
            title: t("other__qr_error_header"),
            description: t("onboarding__restore_seedqr_error")
        )
    }
}
