//
//  NumPad.swift
//  Bitkit
//
//  Created by Assistant on 2024/12/19.
//

import SwiftUI

struct NumPad: View {
    let onPress: (String) -> Void

    private let buttonHeight: CGFloat = 44 + 34
    private let gridItems = Array(repeating: GridItem(.flexible(), spacing: 0), count: 3)
    private let numbers = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "delete"]

    var body: some View {
        LazyVGrid(columns: gridItems, spacing: 0) {
            ForEach(0 ..< 12, id: \.self) { index in
                let item = numbers[index]

                if item.isEmpty {
                    // Empty space
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: buttonHeight)
                } else if item == "delete" {
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
                    }
                    .buttonStyle(NumPadButtonStyle())
                } else {
                    NumPadButton(text: item, height: buttonHeight) {
                        Haptics.play(.buttonTap)
                        onPress(item)
                    }
                }
            }
        }
    }
}
private struct NumPadButton: View {
    let text: String
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.custom(Fonts.medium, size: 24))
                .foregroundColor(.white)
                .kerning(-0.1)
                .frame(maxWidth: .infinity)
                .frame(height: height)
        }
        .buttonStyle(NumPadButtonStyle())
    }
}

private struct NumPadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? Color.white.opacity(0.15) : Color.clear
            )
            .clipShape(Circle())
    }
}

#Preview {
    NumPad { key in
        print("Pressed: \(key)")
    }
    .frame(height: 310)
    .background(Color.black)
}
