import SwiftUI

enum NumberPadActionButtonVariant {
    case primary
    case secondary
}

struct NumberPadActionButton: View {
    let text: String
    var imageName: String?
    var color: Color = .purpleAccent
    var variant: NumberPadActionButtonVariant = .primary
    var disabled: Bool = false
    var action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button {
            Haptics.play(.buttonTap)
            action()
        } label: {
            HStack(spacing: 8) {
                if let imageName {
                    Image(imageName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundColor(color)
                        .frame(width: 16, height: 16)
                }

                CaptionMText(text, textColor: color)
            }
            .frame(height: 28)
            .padding(.horizontal, 8)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(variant == .secondary ? color : Color.clear, lineWidth: 2)
            )
            .cornerRadius(8)
        }
        .disabled(disabled)
        .buttonStyle(NoAnimationButtonStyle())
        .pressEvents(
            onPress: {
                isPressed = true
            },
            onRelease: {
                isPressed = false
            }
        )
    }

    private var background: some View {
        if variant == .secondary {
            return AnyView(Color.clear)
        }

        return AnyView(ButtonGradient(isPressed: isPressed))
    }
}

#Preview {
    VStack(spacing: 20) {
        HStack(spacing: 16) {
            NumberPadActionButton(text: "PRIMARY", variant: .primary) {
                print("PRIMARY tapped")
            }

            NumberPadActionButton(text: "SECONDARY", variant: .secondary) {
                print("SECONDARY tapped")
            }
        }

        HStack(spacing: 16) {
            NumberPadActionButton(text: "MIN") {
                print("MIN tapped")
            }

            NumberPadActionButton(text: "DEFAULT") {
                print("DEFAULT tapped")
            }

            NumberPadActionButton(text: "MAX") {
                print("MAX tapped")
            }

            NumberPadActionButton(
                text: "Bitcoin",
                imageName: "arrow-up-down"
            ) {
                print("Currency toggle tapped")
            }
        }
    }
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
