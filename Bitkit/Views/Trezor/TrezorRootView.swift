import BitkitCore
import SwiftUI

/// Root view for Trezor integration
/// Contains navigation and overlay sheets for PIN/pairing dialogs.
/// The body avoids direct ViewModel access — all @Environment reads
/// are isolated in child views so this view doesn't re-render on every property change.
struct TrezorRootView: View {
    var body: some View {
        VStack(spacing: 0) {
            NetworkSelectorRow()

            ZStack(alignment: .bottom) {
                TrezorContentSwitcher()
                    .frame(maxHeight: .infinity)
                    .padding(.bottom, 40)

                TrezorDebugLogWrapper()
            }
        }
        .modifier(TrezorDialogsModifier())
    }
}

// MARK: - Content Switcher

/// Isolates the connected/disconnected toggle so only this view
/// re-renders when connection state changes.
private struct TrezorContentSwitcher: View {
    @Environment(TrezorViewModel.self) private var trezor

    var body: some View {
        Group {
            if trezor.isConnected {
                TrezorConnectedView()
            } else {
                TrezorDeviceListView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: trezor.isConnected)
        .task {
            trezor.setup()
        }
    }
}

// MARK: - Debug Log Wrapper

/// Isolates the debug log panel's ViewModel binding.
private struct TrezorDebugLogWrapper: View {
    @Environment(TrezorViewModel.self) private var trezor

    var body: some View {
        @Bindable var trezor = trezor
        TrezorDebugLogPanel(
            isExpanded: $trezor.showDebugLog
        )
    }
}

// MARK: - Dialogs Modifier

/// Groups all sheet and overlay presentations that depend on ViewModel state,
/// keeping TrezorRootView's body free of @Environment access.
private struct TrezorDialogsModifier: ViewModifier {
    @Environment(TrezorViewModel.self) private var trezor

    func body(content: Content) -> some View {
        @Bindable var trezor = trezor
        content
            .sheet(isPresented: $trezor.showPinEntry) {
                TrezorPinEntrySheet()
            }
            .sheet(isPresented: $trezor.showPairingCode) {
                TrezorPairingCodeSheet()
            }
            .sheet(isPresented: $trezor.showPassphraseEntry) {
                TrezorPassphraseSheet()
            }
            .overlay {
                if trezor.showConfirmOnDevice {
                    TrezorConfirmOnDeviceOverlay(
                        message: trezor.confirmMessage,
                        onCancel: {
                            trezor.dismissConfirmOnDevice()
                        }
                    )
                }
            }
    }
}

// MARK: - Network Selector

private struct NetworkSelectorRow: View {
    @Environment(TrezorViewModel.self) private var trezor

    private let networks: [(TrezorCoinType, String)] = [
        (.bitcoin, "Bitcoin"),
        (.testnet, "Testnet"),
        (.regtest, "Regtest"),
    ]

    var body: some View {
        VStack(spacing: 8) {
            Text("Dashboard Network")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.4))

            HStack(spacing: 8) {
                ForEach(Array(networks.enumerated()), id: \.offset) { _, item in
                    let (network, label) = item
                    Button(action: { trezor.setSelectedNetwork(network) }) {
                        Text(label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(trezor.selectedNetwork == network ? .white : .white.opacity(0.5))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(trezor.selectedNetwork == network ? Color.white.opacity(0.2) : Color.white.opacity(0.05))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.02))
    }
}

// MARK: - PIN Entry Sheet

struct TrezorPinEntrySheet: View {
    @Environment(TrezorViewModel.self) private var trezor
    @Environment(\.dismiss) private var dismiss
    @State private var pin: String = ""

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Text("Enter PIN")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)

                Text("Look at your Trezor and tap the positions where you see your PIN digits")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            // PIN Pad
            TrezorPinPad(pin: $pin)

            Spacer()

            // Buttons
            HStack(spacing: 16) {
                Button(action: {
                    trezor.cancelPin()
                    dismiss()
                }) {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button(action: {
                    trezor.submitPin(pin)
                    dismiss()
                }) {
                    Text("Confirm")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(pin.isEmpty)
                .opacity(pin.isEmpty ? 0.5 : 1.0)
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 32)
        .padding(.bottom, 16)
        .background(Color.black)
        .interactiveDismissDisabled()
    }
}

// MARK: - Pairing Code Sheet

struct TrezorPairingCodeSheet: View {
    @Environment(TrezorViewModel.self) private var trezor
    @Environment(\.dismiss) private var dismiss
    @State private var code: String = ""
    @State private var hasSubmitted = false

    private let digitCount = 6

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Text("Enter Pairing Code")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)

                Text("Enter the 6-digit code shown on your Trezor screen")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            // Code input
            TrezorPairingCodeInput(code: $code)

            Spacer()

            // Buttons
            HStack(spacing: 16) {
                Button(action: {
                    trezor.cancelPairingCode()
                    dismiss()
                }) {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button(action: {
                    guard !hasSubmitted else { return }
                    hasSubmitted = true
                    trezor.submitPairingCode(code)
                    dismiss()
                }) {
                    Text("Confirm")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(code.count < digitCount || hasSubmitted)
                .opacity(code.count < digitCount || hasSubmitted ? 0.5 : 1.0)
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 32)
        .padding(.bottom, 16)
        .background(Color.black)
        .interactiveDismissDisabled()
        .onChange(of: code) { newValue in
            if newValue.count == digitCount {
                guard !hasSubmitted else { return }
                hasSubmitted = true
                trezor.submitPairingCode(newValue)
                dismiss()
            }
        }
    }
}

// MARK: - Passphrase Sheet

struct TrezorPassphraseSheet: View {
    @Environment(TrezorViewModel.self) private var trezor
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase: String = ""
    @State private var confirmPassphrase: String = ""
    @State private var showPassphrase: Bool = false
    @FocusState private var focusedField: Field?

    enum Field {
        case passphrase
        case confirm
    }

    private var isValid: Bool {
        passphrase == confirmPassphrase
    }

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Text("Enter Passphrase")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)

                Text("Enter your passphrase. Leave empty if you don't use one.")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            // Passphrase fields
            VStack(spacing: 16) {
                SecureInputField(
                    placeholder: "Passphrase",
                    text: $passphrase,
                    showText: showPassphrase
                )
                .focused($focusedField, equals: .passphrase)

                SecureInputField(
                    placeholder: "Confirm Passphrase",
                    text: $confirmPassphrase,
                    showText: showPassphrase
                )
                .focused($focusedField, equals: .confirm)

                // Show/hide toggle
                Button(action: { showPassphrase.toggle() }) {
                    HStack(spacing: 8) {
                        Image(systemName: showPassphrase ? "eye.slash" : "eye")
                        Text(showPassphrase ? "Hide" : "Show")
                    }
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
                }

                // Mismatch warning
                if !passphrase.isEmpty, !confirmPassphrase.isEmpty, !isValid {
                    Text("Passphrases do not match")
                        .font(.system(size: 14))
                        .foregroundColor(.red)
                }
            }
            .padding(.horizontal, 16)

            Spacer()

            // Buttons
            HStack(spacing: 16) {
                Button(action: {
                    trezor.cancelPassphrase()
                    dismiss()
                }) {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button(action: {
                    trezor.submitPassphrase(passphrase)
                    dismiss()
                }) {
                    Text("Confirm")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!isValid)
                .opacity(isValid ? 1.0 : 0.5)
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 32)
        .padding(.bottom, 16)
        .background(Color.black)
        .interactiveDismissDisabled()
        .task {
            focusedField = .passphrase
        }
    }
}

/// Secure text field with show/hide capability
private struct SecureInputField: View {
    let placeholder: String
    @Binding var text: String
    let showText: Bool

    var body: some View {
        Group {
            if showText {
                SwiftUI.TextField(placeholder, text: $text)
            } else {
                SecureField(placeholder, text: $text)
            }
        }
        .font(.system(size: 16))
        .foregroundColor(.white)
        .padding(16)
        .background(Color.white.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Debug Log Panel

struct TrezorDebugLogPanel: View {
    @Binding var isExpanded: Bool
    private var debugLog = TrezorDebugLog.shared

    init(isExpanded: Binding<Bool>) {
        _isExpanded = isExpanded
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toggle bar
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 12))

                    Text("Debug Log (\(debugLog.entries.count))")
                        .font(.system(size: 12, weight: .medium))

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10))
                }
                .foregroundColor(.white.opacity(0.5))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(Color.white.opacity(0.05))

            // Expanded content
            if isExpanded {
                VStack(spacing: 8) {
                    // Action buttons
                    HStack(spacing: 12) {
                        Button(action: {
                            UIPasteboard.general.string = debugLog.copyAll()

                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                Text("Copy All")
                            }
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                        }

                        Button(action: { debugLog.clear() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                Text("Clear")
                            }
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    // Log entries (oldest first, auto-scrolls to newest)
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(debugLog.entries.enumerated()), id: \.offset) { index, entry in
                                    Text(entry)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.6))
                                        .id(index)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .frame(maxHeight: 300)
                        .onChange(of: debugLog.entries.count) { _ in
                            if let lastIndex = debugLog.entries.indices.last {
                                proxy.scrollTo(lastIndex, anchor: .bottom)
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
                .background(Color.black)
                .transition(.opacity)
            }
        }
        .background(Color.black)
    }
}

// MARK: - Preview

#if DEBUG
    struct TrezorRootView_Previews: PreviewProvider {
        static var previews: some View {
            TrezorRootView()
                .environment(TrezorViewModel())
        }
    }
#endif
