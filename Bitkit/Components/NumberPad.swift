import SwiftUI

enum NumberPadType {
    case simple
    case integer
    case decimal
}

struct NumberPad: View {
    let type: NumberPadType
    let errorKey: String?
    let onPress: (String) -> Void

    init(type: NumberPadType = .simple, errorKey: String? = nil, onPress: @escaping (String) -> Void) {
        self.type = type
        self.errorKey = errorKey
        self.onPress = onPress
    }

    private let buttonHeight: CGFloat = UIScreen.main.isSmall ? 65 : 44 + 34
    private let gridItems = Array(repeating: GridItem(.flexible(), spacing: 0), count: 3)
    private let numbers = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

    var body: some View {
        VStack(spacing: 0) {
            // Top 3 rows (1-9)
            LazyVGrid(columns: gridItems, spacing: 0) {
                ForEach(numbers, id: \.self) { number in
                    NumberPadButton(
                        text: number,
                        height: buttonHeight,
                        hasError: errorKey == number,
                        testID: "N\(number)"
                    ) {
                        Haptics.play(.buttonTap)
                        onPress(number)
                    }
                }
            }

            // Bottom row with type-specific left button, 0, and delete
            HStack(spacing: 0) {
                // Left button based on type
                Group {
                    switch type {
                    case .simple:
                        Rectangle()
                            .fill(Color.clear)
                            .frame(height: buttonHeight)
                    case .integer:
                        NumberPadButton(
                            text: "000",
                            height: buttonHeight,
                            hasError: errorKey == "000",
                            testID: "N000"
                        ) {
                            Haptics.play(.buttonTap)
                            onPress("000")
                        }
                    case .decimal:
                        NumberPadButton(
                            text: ".",
                            height: buttonHeight,
                            hasError: errorKey == ".",
                            testID: "NDecimal"
                        ) {
                            Haptics.play(.buttonTap)
                            onPress(".")
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                // Zero button
                NumberPadButton(
                    text: "0",
                    height: buttonHeight,
                    hasError: errorKey == "0",
                    testID: "N0"
                ) {
                    Haptics.play(.buttonTap)
                    onPress("0")
                }
                .frame(maxWidth: .infinity)

                // Delete button
                Button(action: {
                    Haptics.play(.buttonTap)
                    onPress("delete")
                }) {
                    Image(systemName: "delete.left")
                        .font(.title2)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: buttonHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NumberPadButtonStyle())
                .accessibilityIdentifier("NRemove")
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct NumberPadButton: View {
    let text: String
    let height: CGFloat
    let hasError: Bool
    var testID: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.custom(Fonts.medium, size: 24))
                .foregroundColor(hasError ? .redAccent : .white)
                .kerning(-0.1)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier(testID ?? text)
        .buttonStyle(NumberPadButtonStyle())
    }
}

private struct NumberPadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.white.opacity(0.15) : Color.clear)
    }
}

#Preview {
    NumberPad(type: .integer, errorKey: nil) { key in
        print("Pressed: \(key)")
    }
    .frame(height: 310)
    .background(Color.black)
}
