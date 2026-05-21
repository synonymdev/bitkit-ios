import SwiftUI

/// Inline content for public key retrieval, used by expandable section.
struct TrezorPublicKeyContent: View {
    @Environment(TrezorViewModel.self) private var trezor

    var body: some View {
        @Bindable var trezor = trezor
        VStack(spacing: 24) {
            // Account path
            VStack(alignment: .leading, spacing: 12) {
                Text("Account Path")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))

                SwiftUI.TextField("m/84'/0'/0'", text: $trezor.publicKeyPath)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Show on device toggle
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Show on Trezor")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                    Text("Display public key on device for verification")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                }

                Spacer()

                Toggle("", isOn: $trezor.showPublicKeyOnDevice)
                    .labelsHidden()
                    .tint(.green)
            }
            .padding(16)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Get Public Key button
            Button(action: {
                Task {
                    await trezor.getPublicKey(showOnDevice: trezor.showPublicKeyOnDevice)
                }
            }) {
                HStack(spacing: 8) {
                    if trezor.isOperating {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .black))
                    } else {
                        Image(systemName: "key")
                    }
                    Text("Get Public Key")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(trezor.isOperating)

            // Results
            if let xpub = trezor.xpub {
                CopyableField(label: "Extended Public Key (xpub)", value: xpub)
            }

            if let pubKey = trezor.publicKeyHex {
                CopyableField(label: "Compressed Public Key", value: pubKey)
            }

            // Error
            if let error = trezor.error {
                TrezorErrorBanner(message: error)
            }
        }
    }
}

/// Full-screen view for retrieving xpub and public key from Trezor (used for previews)
struct TrezorPublicKeyView: View {
    var body: some View {
        ScrollView {
            TrezorPublicKeyContent()
                .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.black)
        .navigationTitle("Public Key")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Copyable Field

private struct CopyableField: View {
    let label: String
    let value: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))

            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Button(action: {
                UIPasteboard.general.string = value

                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    copied = false
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    Text(copied ? "Copied!" : "Copy")
                }
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Preview

#if DEBUG
    struct TrezorPublicKeyView_Previews: PreviewProvider {
        static var previews: some View {
            NavigationStack {
                TrezorPublicKeyView()
            }
            .environment(TrezorViewModel())
        }
    }
#endif
