import BitkitCore
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - Script Type

enum TrezorAddressScriptType: String, CaseIterable {
    case legacy = "Legacy (P2PKH)"
    case segwit = "Native SegWit (P2WPKH)"
    case nestedSegwit = "Nested SegWit (P2SH-P2WPKH)"
    case taproot = "Taproot (P2TR)"

    var trezorScriptType: TrezorScriptType {
        switch self {
        case .legacy:
            return .spendAddress
        case .segwit:
            return .spendWitness
        case .nestedSegwit:
            return .spendP2shWitness
        case .taproot:
            return .spendTaproot
        }
    }

    func defaultPath(coinType: String) -> String {
        switch self {
        case .legacy:
            return "m/44'/\(coinType)/0'/0/0"
        case .segwit:
            return "m/84'/\(coinType)/0'/0/0"
        case .nestedSegwit:
            return "m/49'/\(coinType)/0'/0/0"
        case .taproot:
            return "m/86'/\(coinType)/0'/0/0"
        }
    }
}

/// Inline content for address generation, used by expandable section.
struct TrezorAddressContent: View {
    @Environment(TrezorViewModel.self) private var trezor
    @State private var selectedScriptType: TrezorAddressScriptType = .segwit

    var body: some View {
        VStack(spacing: 24) {
            AddressTypeSection(selectedScriptType: $selectedScriptType)
            DerivationPathSection(selectedScriptType: selectedScriptType)
            VerifyOnDeviceSection()
            GenerateButtonSection()
            AddressResultSection()
        }
        .onChange(of: selectedScriptType) { newValue in
            trezor.derivationPath = newValue.defaultPath(coinType: trezor.coinTypeComponent)
            trezor.selectedScriptType = newValue.trezorScriptType
            trezor.addressIndex = 0
        }
        .task {
            trezor.selectedScriptType = selectedScriptType.trezorScriptType
        }
    }
}

/// Full-screen view for generating addresses from Trezor (used for previews)
struct TrezorAddressView: View {
    var body: some View {
        ScrollView {
            TrezorAddressContent()
                .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.black)
        .navigationTitle("Get Address")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Address Type Section

private struct AddressTypeSection: View {
    @Binding var selectedScriptType: TrezorAddressScriptType

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Address Type")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            Picker("Script Type", selection: $selectedScriptType) {
                ForEach(TrezorAddressScriptType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.menu)
            .tint(.green)
            .padding(12)
            .background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Derivation Path Section

private struct DerivationPathSection: View {
    @Environment(TrezorViewModel.self) private var trezor
    let selectedScriptType: TrezorAddressScriptType
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        @Bindable var trezor = trezor
        VStack(alignment: .leading, spacing: 12) {
            Text("Derivation Path")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            SwiftUI.TextField("m/84'/0'/0'/0/0", text: $trezor.derivationPath)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.white)
                .focused($isFieldFocused)
                .submitLabel(.done)
                .onSubmit {
                    isFieldFocused = false
                }
                .padding(12)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Address index stepper
            HStack {
                Text("Address Index: \(trezor.addressIndex)")
                    .font(.system(size: 14))
                    .foregroundColor(.white)

                Spacer()

                Button(action: { trezor.decrementAddressIndex() }) {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 20))
                        .foregroundColor(trezor.addressIndex == 0 ? .white.opacity(0.2) : .white.opacity(0.6))
                }
                .disabled(trezor.addressIndex == 0)

                Button(action: { trezor.incrementAddressIndex() }) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Button(action: {
                trezor.derivationPath = selectedScriptType.defaultPath(coinType: trezor.coinTypeComponent)
                trezor.addressIndex = 0
            }) {
                Text("Use default path")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    isFieldFocused = false
                }
            }
        }
    }
}

// MARK: - Verify On Device Section

private struct VerifyOnDeviceSection: View {
    @Environment(TrezorViewModel.self) private var trezor

    var body: some View {
        @Bindable var trezor = trezor
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Verify on Trezor")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                Text("Display address on device for verification")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
            }

            Spacer()

            Toggle("", isOn: $trezor.showAddressOnDevice)
                .labelsHidden()
                .tint(.green)
        }
        .padding(16)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Generate Button Section

private struct GenerateButtonSection: View {
    @Environment(TrezorViewModel.self) private var trezor

    var body: some View {
        Button(action: {
            Task {
                await trezor.getAddress(showOnDevice: trezor.showAddressOnDevice)
            }
        }) {
            HStack(spacing: 8) {
                if trezor.isOperating {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .black))
                } else {
                    Image(systemName: "qrcode")
                }
                Text("Generate Address")
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(trezor.isOperating)
    }
}

// MARK: - Address Result Section

private struct AddressResultSection: View {
    @Environment(TrezorViewModel.self) private var trezor

    var body: some View {
        VStack(spacing: 24) {
            if let address = trezor.generatedAddress {
                GeneratedAddressCard(address: address)

                // Next Index button
                Button(action: {
                    trezor.incrementAddressIndex()
                    trezor.generatedAddress = nil
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.right")
                        Text("Next Index (\(trezor.addressIndex + 1))")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Capsule())
                }
            }

            if let error = trezor.error {
                TrezorErrorBanner(message: error)
            }
        }
    }
}

// MARK: - Generated Address Card

private struct GeneratedAddressCard: View {
    let address: String
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            QRCodeView(content: address)
            AddressText(address: address)
            CopyButton(address: address, copied: $copied)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct QRCodeView: View {
    let content: String
    @State private var qrImage: UIImage?

    var body: some View {
        Group {
            if let qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white)
                        .frame(width: 180, height: 180)

                    Image(systemName: "qrcode")
                        .font(.system(size: 80))
                        .foregroundColor(.black.opacity(0.2))
                }
            }
        }
        .task(id: content) {
            qrImage = Self.generateQRCode(from: content)
        }
    }

    private static func generateQRCode(from string: String) -> UIImage? {
        let data = string.data(using: .utf8)

        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return nil
        }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")

        guard let ciImage = filter.outputImage else {
            return nil
        }

        let scale = 10.0
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaledImage = ciImage.transformed(by: transform)

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}

private struct AddressText: View {
    let address: String

    var body: some View {
        Text(address)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
    }
}

private struct CopyButton: View {
    let address: String
    @Binding var copied: Bool

    var body: some View {
        Button(action: copyAddress) {
            HStack(spacing: 8) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                Text(copied ? "Copied!" : "Copy Address")
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.15))
            .clipShape(Capsule())
        }
    }

    private func copyAddress() {
        UIPasteboard.general.string = address
        copied = true


        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct TrezorAddressView_Previews: PreviewProvider {
        static var previews: some View {
            NavigationStack {
                TrezorAddressView()
            }
            .environment(TrezorViewModel())
        }
    }
#endif
