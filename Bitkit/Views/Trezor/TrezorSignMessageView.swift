import BitkitCore
import SwiftUI

// MARK: - Sign/Verify Tab

enum TrezorSignMessageTab: String, CaseIterable {
    case sign = "Sign"
    case verify = "Verify"
}

/// Inline content for message signing, used by expandable section.
struct TrezorSignMessageContent: View {
    @State private var verifyAddress: String = ""
    @State private var verifySignature: String = ""
    @State private var verifyMessage: String = ""
    @State private var verificationResult: Bool?
    @State private var selectedTab: TrezorSignMessageTab = .sign

    var body: some View {
        VStack(spacing: 16) {
            Picker("Mode", selection: $selectedTab) {
                ForEach(TrezorSignMessageTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            switch selectedTab {
            case .sign:
                SignMessageContent()
            case .verify:
                VerifyMessageContent(
                    address: $verifyAddress,
                    signature: $verifySignature,
                    message: $verifyMessage,
                    verificationResult: $verificationResult
                )
            }
        }
    }
}

/// Full-screen view for signing messages with Trezor (used for previews)
struct TrezorSignMessageView: View {
    var body: some View {
        ScrollView {
            TrezorSignMessageContent()
                .padding(16)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Color.black)
        .navigationTitle("Message Signing")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Sign Message Content

private struct SignMessageContent: View {
    @Environment(TrezorViewModel.self) private var trezor
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        @Bindable var trezor = trezor
        VStack(spacing: 24) {
            // Derivation path
            VStack(alignment: .leading, spacing: 8) {
                Text("Derivation Path")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))

                SwiftUI.TextField("m/84'/0'/0'/0/0", text: $trezor.messageSigningPath)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.white)
                    .focused($isFieldFocused)
                    .submitLabel(.next)
                    .padding(12)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Message input
            VStack(alignment: .leading, spacing: 8) {
                Text("Message to Sign")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))

                SwiftUI.TextField("Enter message...", text: $trezor.messageToSign, axis: .vertical)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .lineLimit(5 ... 10)
                    .focused($isFieldFocused)
                    .padding(12)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Sign button
            Button(action: {
                isFieldFocused = false
                Task {
                    await trezor.signMessage()
                }
            }) {
                HStack(spacing: 8) {
                    if trezor.isOperating {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .black))
                    } else {
                        Image(systemName: "signature")
                    }
                    Text("Sign Message")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(trezor.isOperating || trezor.messageToSign.isEmpty)
            .opacity(trezor.messageToSign.isEmpty ? 0.5 : 1.0)

            // Result display
            if let signedMessage = trezor.signedMessage {
                SignedMessageResult(response: signedMessage)
            }

            // Error display
            if let error = trezor.error {
                TrezorErrorBanner(message: error)
            }
        }
        .padding(16)
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

// MARK: - Verify Message Content

private struct VerifyMessageContent: View {
    @Environment(TrezorViewModel.self) private var trezor
    @Binding var address: String
    @Binding var signature: String
    @Binding var message: String
    @Binding var verificationResult: Bool?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            // Address input
            VStack(alignment: .leading, spacing: 8) {
                Text("Signing Address")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))

                SwiftUI.TextField("bc1q...", text: $address)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.white)
                    .focused($isFieldFocused)
                    .submitLabel(.next)
                    .padding(12)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Signature input
            VStack(alignment: .leading, spacing: 8) {
                Text("Signature (Base64)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))

                SwiftUI.TextField("Signature", text: $signature)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white)
                    .focused($isFieldFocused)
                    .submitLabel(.next)
                    .padding(12)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Message input
            VStack(alignment: .leading, spacing: 8) {
                Text("Original Message")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))

                SwiftUI.TextField("Enter message...", text: $message, axis: .vertical)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .lineLimit(4 ... 8)
                    .focused($isFieldFocused)
                    .padding(12)
                    .background(Color.white.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Verify button
            Button(action: {
                isFieldFocused = false
                Task {
                    verificationResult = await trezor.verifyMessage(
                        address: address,
                        signature: signature,
                        message: message
                    )
                }
            }) {
                HStack(spacing: 8) {
                    if trezor.isOperating {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .black))
                    } else {
                        Image(systemName: "checkmark.shield")
                    }
                    Text("Verify Signature")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(trezor.isOperating || !isFormValid)
            .opacity(isFormValid ? 1.0 : 0.5)

            // Verification result
            if let result = verificationResult {
                VerificationResultBanner(isValid: result)
            }

            // Error display
            if let error = trezor.error {
                TrezorErrorBanner(message: error)
            }
        }
        .padding(16)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    isFieldFocused = false
                }
            }
        }
    }

    private var isFormValid: Bool {
        !address.isEmpty && !signature.isEmpty && !message.isEmpty
    }
}

// MARK: - Signed Message Result

private struct SignedMessageResult: View {
    let response: TrezorSignedMessageResponse
    @State private var copiedSignature = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Signature")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)

            // Address
            VStack(alignment: .leading, spacing: 4) {
                Text("Address:")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))

                Text(response.address)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white)
            }

            // Signature
            VStack(alignment: .leading, spacing: 4) {
                Text("Signature (Base64):")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))

                Text(response.signature)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(3)
            }

            // Copy button
            Button(action: {
                UIPasteboard.general.string = response.signature
                copiedSignature = true


                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    copiedSignature = false
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: copiedSignature ? "checkmark" : "doc.on.doc")
                    Text(copiedSignature ? "Copied!" : "Copy Signature")
                }
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Verification Result Banner

private struct VerificationResultBanner: View {
    let isValid: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(isValid ? .green : .red)

            Text(isValid ? "Signature is valid" : "Signature is invalid")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)

            Spacer()
        }
        .padding(16)
        .background((isValid ? Color.green : Color.red).opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Preview

#if DEBUG
    struct TrezorSignMessageView_Previews: PreviewProvider {
        static var previews: some View {
            NavigationStack {
                TrezorSignMessageView()
            }
            .environment(TrezorViewModel())
        }
    }
#endif
