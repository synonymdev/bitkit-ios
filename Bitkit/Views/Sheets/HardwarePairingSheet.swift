import SwiftUI

struct HardwarePairingSheetItem: SheetItem {
    let id: SheetID = .hardwarePairing
    let size: SheetSize = .large
}

/// App-wide sheet for the one-time pairing code a hardware device shows during connect/reconnect.
/// Dismissing without entering the full code cancels the pending pairing request.
struct HardwarePairingSheet: View {
    @Environment(TrezorManager.self) private var trezorManager
    let config: HardwarePairingSheetItem

    private let codeLength = 6
    private let cellWidth: CGFloat = 32

    @State private var code = ""
    @State private var submitted = false

    var body: some View {
        Sheet(id: .hardwarePairing, data: config) {
            VStack(spacing: 0) {
                SheetHeader(title: t("hardware__pairing_title"))
                    .padding(.horizontal, 16)

                VStack(spacing: 0) {
                    BodyMText(t("hardware__pairing_text"))
                        .multilineTextAlignment(.center)

                    Spacer()

                    HStack(spacing: 8) {
                        ForEach(0 ..< codeLength, id: \.self) { index in
                            let digit = digit(at: index)
                            DisplayText(digit ?? "•", textColor: digit != nil ? .textPrimary : .white32)
                                .frame(width: cellWidth)
                        }
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 32)

                NumberPad(type: .simple, onPress: handleKey)
                    .frame(height: NumberPad.contentHeight)
            }
            .accessibilityIdentifier("HwPairSheet")
        }
        .onDisappear {
            if !submitted { trezorManager.cancelPairingCode() }
        }
    }

    private func digit(at index: Int) -> String? {
        let characters = Array(code)
        return index < characters.count ? String(characters[index]) : nil
    }

    private func handleKey(_ key: String) {
        if key == "delete" {
            if !code.isEmpty { code.removeLast() }
        } else if code.count < codeLength {
            code += key
            if code.count == codeLength {
                submitted = true
                trezorManager.submitPairingCode(code)
            }
        }
    }
}

#Preview {
    HardwarePairingSheet(config: HardwarePairingSheetItem())
        .environmentObject(SheetViewModel())
        .environment(TrezorManager())
        .preferredColorScheme(.dark)
}
