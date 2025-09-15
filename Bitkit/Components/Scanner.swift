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
                .onChange(of: selectedItem) { item in
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
    let onScan: (String) async -> Void
    let onImageSelection: (PhotosPickerItem?) async -> Void

    @State private var isTorchOn = false

    var body: some View {
        ZStack {
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
        }
        .cornerRadius(16)
    }
}
