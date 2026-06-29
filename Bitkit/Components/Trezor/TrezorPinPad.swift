import SwiftUI

/// 3x3 PIN pad for Trezor PIN entry
/// Trezor displays a scrambled keypad on device, user taps positions 1-9 in app
struct TrezorPinPad: View {
    /// Current PIN being entered
    @Binding var pin: String

    /// Maximum PIN length. Trezor PINs can be up to 50 digits.
    var maxLength: Int = 50

    /// Number of entered-digit dots to render per row before wrapping.
    private let dotsPerRow = 9

    /// PIN pad layout (positions map to device keypad)
    /// The Trezor shows scrambled numbers, we show only position dots
    private let positions = [
        ["7", "8", "9"],
        ["4", "5", "6"],
        ["1", "2", "3"],
    ]

    var body: some View {
        VStack(spacing: 16) {
            // PIN display — one dot per entered digit, wrapping across rows so long
            // PINs (Trezor allows up to 50 digits) don't overflow a single line.
            VStack(spacing: 8) {
                if pin.isEmpty {
                    // Placeholder row so the layout doesn't collapse before entry.
                    HStack(spacing: 12) {
                        ForEach(0 ..< dotsPerRow, id: \.self) { _ in
                            Circle()
                                .fill(Color.white.opacity(0.3))
                                .frame(width: 12, height: 12)
                        }
                    }
                } else {
                    let rowCount = (pin.count + dotsPerRow - 1) / dotsPerRow
                    ForEach(0 ..< rowCount, id: \.self) { row in
                        let dotsInRow = min(dotsPerRow, pin.count - row * dotsPerRow)
                        HStack(spacing: 12) {
                            ForEach(0 ..< dotsInRow, id: \.self) { _ in
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 12, height: 12)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 24)

            // Keypad
            VStack(spacing: 12) {
                ForEach(positions, id: \.self) { row in
                    HStack(spacing: 12) {
                        ForEach(row, id: \.self) { position in
                            PinButton(position: position) {
                                handleDigitTap(position)
                            }
                        }
                    }
                }
            }

            // Delete button
            HStack {
                Spacer()

                Button(action: handleDelete) {
                    Image(systemName: "delete.left")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                        .frame(width: 64, height: 48)
                }
                .disabled(pin.isEmpty)
                .opacity(pin.isEmpty ? 0.3 : 1.0)
                .accessibilityIdentifier("TrezorPinDelete")
            }
            .padding(.top, 8)
        }
        .padding(16)
        .accessibilityIdentifier("TrezorPinPad")
    }

    private func handleDigitTap(_ position: String) {
        guard pin.count < maxLength else { return }
        pin += position
    }

    private func handleDelete() {
        guard !pin.isEmpty else { return }
        pin.removeLast()
    }
}

/// Individual PIN pad button
private struct PinButton: View {
    let position: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 72, height: 72)
                .overlay(
                    // Show a dot instead of number (Trezor shows scrambled numbers on device)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 16, height: 16)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityIdentifier("TrezorPinPosition-\(position)")
    }
}

// MARK: - Preview

#if DEBUG
    struct TrezorPinPad_Previews: PreviewProvider {
        static var previews: some View {
            ZStack {
                Color.black.ignoresSafeArea()

                TrezorPinPad(pin: .constant("123"))
            }
        }
    }
#endif
