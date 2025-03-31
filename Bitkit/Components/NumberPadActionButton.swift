//
//  NumberPadActionButton.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/12.
//

import SwiftUI

struct NumberPadActionButton: View {
    let text: String
    var imageName: String?
    var color: Color = .purpleAccent
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
                        .frame(height: 12)
                }

                CaptionText(text.uppercased(), textColor: color)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(Color.white10)
            .cornerRadius(8)
        }
    }
}

#Preview {
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
            text: "BTC",
            imageName: "transfer-purple"
        ) {
            print("Currency toggle tapped")
        }
    }
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
