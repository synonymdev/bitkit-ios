import SwiftUI

/// Inline one-time THP pairing-code step shown when a device asks for its 6-digit code mid-connect.
/// On the sixth digit the code row collapses into a spinner while pairing completes.
struct HwPairCodeView: View {
    let onSubmit: (String) -> Void

    private let codeLength = 6
    private let cellWidth: CGFloat = 32
    private let cellSpacing: CGFloat = 8

    @State private var code = ""
    @State private var submitted = false

    private var progress: CGFloat {
        submitted ? 1 : 0
    }

    private var cellStep: CGFloat {
        cellWidth + cellSpacing
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("hardware__pairing_title"))
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                BodyMText(t("hardware__pairing_text"))
                    .multilineTextAlignment(.center)

                Spacer()

                codeRow
                    .overlay {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .brandAccent))
                            .frame(width: 32, height: 32)
                            .opacity(progress)
                            .scaleEffect(0.8 + 0.2 * progress)
                    }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)

            NumberPad(type: .simple, isDisabled: submitted, onPress: handleKey)
                .frame(height: NumberPad.contentHeight)
        }
        .accessibilityIdentifier("HardwareWalletPairCodeScreen")
    }

    /// Fixed-width cells so digits replace dots without the row shifting; on submit each cell
    /// collapses toward the center and fades so the spinner can take its place.
    private var codeRow: some View {
        HStack(spacing: cellSpacing) {
            ForEach(0 ..< codeLength, id: \.self) { index in
                let digit = digit(at: index)
                let centerOffset = CGFloat(codeLength - 1) / 2 - CGFloat(index)
                DisplayText(digit ?? "•", textColor: digit != nil ? .textPrimary : .white32)
                    .frame(width: cellWidth)
                    .opacity(1 - progress)
                    .scaleEffect(x: 1 - 0.85 * progress, y: 1 - 0.15 * progress)
                    .offset(x: centerOffset * cellStep * progress)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: submitted)
    }

    private func digit(at index: Int) -> String? {
        let characters = Array(code)
        return index < characters.count ? String(characters[index]) : nil
    }

    private func handleKey(_ key: String) {
        guard !submitted else { return }
        if key == "delete" {
            if !code.isEmpty { code.removeLast() }
        } else if code.count < codeLength {
            code += key
            if code.count == codeLength {
                submitted = true
                onSubmit(code)
            }
        }
    }
}

#Preview {
    HwPairCodeView(onSubmit: { _ in })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .preferredColorScheme(.dark)
}
