//
//  SwipeButton.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/11/20.
//

import SwiftUI

struct SwipeButton: View {
    let onComplete: () -> Void

    @State private var offset: CGFloat = 0
    @State private var isDragging = false

    private let buttonHeight: CGFloat = 70
    private let innerPadding: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Button background
                RoundedRectangle(cornerRadius: buttonHeight / 2)
                    .fill(Color.gray)
                    .opacity(0.2)
                    .overlay {
                        Text("Swipe To Pay")
                            .bold()
                            .opacity(1.0 - (offset / (geometry.size.width - 80)))
                    }

                // Sliding circle
                Circle()
                    .fill(Color.green)
                    .frame(width: buttonHeight - innerPadding, height: buttonHeight - innerPadding)
                    .overlay(
                        Image(systemName: "arrow.right")
                            .foregroundColor(.white)
                    )
                    .offset(x: max(0, min(offset, geometry.size.width - 60)))
                    .padding(.horizontal, innerPadding / 2)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                isDragging = true
                                offset = value.translation.width
                            }
                            .onEnded { _ in
                                isDragging = false
                                if offset > geometry.size.width - 80 {
                                    // Completed the swipe
                                    withAnimation {
                                        offset = geometry.size.width - 60
                                    }
                                    onComplete()
                                } else {
                                    // Reset position
                                    withAnimation {
                                        offset = 0
                                    }
                                }
                            }
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: buttonHeight)
    }
}

#Preview {
    SwipeButton {
        print("Swiped")
    }
}
