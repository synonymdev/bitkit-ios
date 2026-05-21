import SwiftUI

/// Badge showing Trezor connection status
struct TrezorStatusBadge: View {
    let isConnected: Bool
    let deviceName: String?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
        }
    }

    private var statusText: String {
        if isConnected {
            return deviceName ?? "Connected"
        }
        return "Not Connected"
    }
}

/// Confirm on device overlay
struct TrezorConfirmOnDeviceOverlay: View {
    let message: String
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(spacing: 24) {
            // Trezor icon
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 48))
                .foregroundColor(.white)
                .padding(24)
                .background(Color.white.opacity(0.1))
                .clipShape(Circle())

            VStack(spacing: 8) {
                Text("Action Required")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)

                Text(message)
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            // Pulsing indicator
            PulsingDots()
                .frame(height: 32)

            if let onCancel {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
                .padding(.top, 8)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.9))
    }
}

/// Animated pulsing dots indicator
private struct PulsingDots: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0 ..< 3) { index in
                Circle()
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
                    .scaleEffect(isAnimating ? 1.0 : 0.5)
                    .opacity(isAnimating ? 1.0 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.2),
                        value: isAnimating
                    )
            }
        }
        .onAppear {
            isAnimating = true
        }
    }
}

/// Reusable error banner for Trezor views.
/// NOTE: Intentionally used instead of app.toast() in the Trezor dev dashboard.
/// Inline error display provides better visibility for debugging BLE/THP protocol
/// issues during development. See CLAUDE.md for production error handling patterns.
struct TrezorErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.red)

            Text(message)
                .font(.system(size: 14))
                .foregroundColor(.white)

            Spacer()
        }
        .padding(16)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Preview

#if DEBUG
    struct TrezorStatusBadge_Previews: PreviewProvider {
        static var previews: some View {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 24) {
                    TrezorStatusBadge(isConnected: true, deviceName: "My Trezor")
                    TrezorStatusBadge(isConnected: false, deviceName: nil)
                }
            }
        }
    }

    struct TrezorConfirmOnDeviceOverlay_Previews: PreviewProvider {
        static var previews: some View {
            TrezorConfirmOnDeviceOverlay(
                message: "Confirm the address on your Trezor",
                onCancel: {}
            )
        }
    }
#endif
