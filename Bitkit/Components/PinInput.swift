import SwiftUI

struct PinInput: View {
    @Binding var pinInput: String
    var verticalSpace = false
    let onPinChange: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // PIN circles
            HStack(alignment: .top, spacing: 24) {
                ForEach(0 ..< 4, id: \.self) { index in
                    Circle()
                        .fill(index < pinInput.count ? Color.brandAccent : Color.brandAccent.opacity(0.08))
                        .overlay(
                            Circle()
                                .stroke(Color.brandAccent, lineWidth: 1)
                        )
                        .frame(width: 20, height: 20)
                }
            }
            .padding(.bottom, 32)

            if verticalSpace {
                Spacer()
            }

            NumPad { key in
                handleNumPadInput(key)
            }
            .background(Color.black)
        }
    }

    private func handleNumPadInput(_ key: String) {
        if key == "delete" {
            if !pinInput.isEmpty {
                pinInput = String(pinInput.dropLast())
            }
            // Call the callback immediately for delete
            onPinChange(pinInput)
        } else if pinInput.count < 4 {
            pinInput += key

            // If it's the 4th number, add a delay before calling onPinChange
            if pinInput.count == 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    onPinChange(pinInput)
                }
            } else {
                // Call the callback immediately for other inputs
                onPinChange(pinInput)
            }
        }
    }
}

#Preview {
    PinInput(pinInput: .constant("123")) { pin in
        print("PIN changed: \(pin)")
    }
    .preferredColorScheme(.dark)
}
