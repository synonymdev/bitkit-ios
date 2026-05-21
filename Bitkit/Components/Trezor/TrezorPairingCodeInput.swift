import SwiftUI

/// 6-digit pairing code input for Trezor BLE pairing
/// User enters the code displayed on the Trezor device screen
struct TrezorPairingCodeInput: View {
    /// Current pairing code being entered
    @Binding var code: String

    /// Number of digits in pairing code
    let digitCount: Int = 6

    /// Focus state for keyboard
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            // Code display boxes
            HStack(spacing: 12) {
                ForEach(0 ..< digitCount, id: \.self) { index in
                    CodeDigitBox(
                        digit: getDigit(at: index),
                        isActive: index == code.count && isFocused
                    )
                }
            }

            // Hidden text field for keyboard input
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .focused($isFocused)
                .frame(width: 1, height: 1)
                .opacity(0.01) // Nearly invisible but still functional
                .onChange(of: code) { newValue in
                    // Filter to only digits and limit length
                    let filtered = newValue.filter(\.isNumber)
                    if filtered.count <= digitCount {
                        code = filtered
                    } else {
                        code = String(filtered.prefix(digitCount))
                    }
                }
        }
        .onTapGesture {
            isFocused = true
        }
        .task {
            // Brief delay for sheet presentation animation to complete
            try? await Task.sleep(nanoseconds: 200_000_000)
            isFocused = true
        }
    }

    /// Get digit at specific index, or nil if not entered yet
    private func getDigit(at index: Int) -> Character? {
        guard index < code.count else { return nil }
        return code[code.index(code.startIndex, offsetBy: index)]
    }
}

/// Individual digit display box
private struct CodeDigitBox: View {
    let digit: Character?
    let isActive: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.1))
                .frame(width: 48, height: 56)

            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.white : Color.white.opacity(0.3), lineWidth: isActive ? 2 : 1)
                .frame(width: 48, height: 56)

            if let digit {
                Text(String(digit))
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }
}

// MARK: - Preview

#if DEBUG
    struct TrezorPairingCodeInput_Previews: PreviewProvider {
        static var previews: some View {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 40) {
                    TrezorPairingCodeInput(code: .constant(""))
                    TrezorPairingCodeInput(code: .constant("123"))
                    TrezorPairingCodeInput(code: .constant("123456"))
                }
            }
        }
    }
#endif
