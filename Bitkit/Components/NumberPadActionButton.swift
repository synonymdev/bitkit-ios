//
//  NumberPadActionButton.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/12.
//

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
    var action: () -> Void

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
                        .frame(height: 16)
                }

                CaptionMText(text.uppercased(), textColor: color)
            }
            .frame(height: 28)
            .padding(.horizontal, 8)
            .background(variant == .primary ? Color.white10 : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(variant == .secondary ? color : Color.clear, lineWidth: 1)
            )
            .cornerRadius(8)
        }
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
                imageName: "transfer-purple"
            ) {
                print("Currency toggle tapped")
            }
        }
    }
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
