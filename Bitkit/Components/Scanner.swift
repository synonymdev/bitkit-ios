import CodeScanner
import PhotosUI
import SwiftUI

// MARK: - Scanner Camera Component

private struct ScannerCamera: View {
    let isTorchOn: Bool
    let onScan: (String) async -> Void

    var body: some View {
        CodeScannerView(codeTypes: [.qr], shouldVibrateOnSuccess: false, isTorchOn: isTorchOn) { response in
            if case let .success(result) = response {
                Task {
                    await onScan(result.string)
                }
            } else if case let .failure(error) = response {
                Logger.error(error, context: "CodeScanner")
            }
        }
    }
}

// MARK: - Scanner Corner Buttons Component

private struct ScannerCornerButtons: View {
    @Binding var isTorchOn: Bool
    let onImageSelection: (PhotosPickerItem?) async -> Void

    @State private var selectedItem: PhotosPickerItem?

    var body: some View {
        GeometryReader { _ in
            HStack {
                PhotosPicker(selection: $selectedItem, matching: .images) {
                    Image("picture")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.white16)
                        .clipShape(Circle())
                }
                .onChange(of: selectedItem) { _, item in
                    Task { await onImageSelection(item) }
                }

                Spacer()

                IconButton(icon: Image("flashlight"), size: 40) {
                    isTorchOn.toggle()
                }
                .background(isTorchOn ? Color.white32 : Color.clear)
                .clipShape(Circle())
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Scanner Component

struct Scanner: View {
    @Environment(CameraManager.self) private var cameraManager

    let onScan: (String) async -> Void
    let onImageSelection: (PhotosPickerItem?) async -> Void

    @State private var isTorchOn = false

    var body: some View {
        ZStack {
            if cameraManager.hasPermission {
                ScannerCamera(
                    isTorchOn: isTorchOn,
                    onScan: { uri in
                        await onScan(uri)
                    }
                )

                ScannerCornerButtons(
                    isTorchOn: $isTorchOn,
                    onImageSelection: { item in
                        await onImageSelection(item)
                    }
                )
            } else {
                ScannerPermissionRequest(onRequestPermission: cameraManager.requestPermission)
            }
        }
        .cornerRadius(16)
        .onAppear {
            guard !cameraManager.hasPermission else { return }
            cameraManager.requestPermissionIfNeeded()
        }
    }
}

struct ScannerPermissionRequest: View {
    let onRequestPermission: () -> Void

    var body: some View {
        Color.black
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                VStack(spacing: 0) {
                    DisplayText(t("other__camera_no_title"), accentColor: .brandAccent)
                        .padding(.bottom, 8)
                    BodyMText(t("other__camera_no_text"))
                        .padding(.bottom, 32)
                    CustomButton(
                        title: t("other__camera_no_button"),
                        icon: Image("camera").foregroundColor(.textPrimary)
                    ) {
                        onRequestPermission()
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
            }
    }
}
