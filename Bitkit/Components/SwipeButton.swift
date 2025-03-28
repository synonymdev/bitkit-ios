//
//  SwipeButton.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/11/20.
//

import SwiftUI

struct SwipeButton: View {
    let title: String
    let accentColor: Color
    let onComplete: () async throws -> Void

    @State private var offset: CGFloat = 0
    @State private var isDragging = false
    @State private var isLoading = false

    private let buttonHeight: CGFloat = 70
    private let innerPadding: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Button background
                RoundedRectangle(cornerRadius: buttonHeight / 2)
                    .fill(Color.gray)
                    .opacity(0.2)

                // Colored trail
                RoundedRectangle(cornerRadius: buttonHeight / 2)
                    .fill(accentColor.opacity(0.2))
                    .frame(width: max(0, min(offset + (buttonHeight - innerPadding), geometry.size.width - innerPadding)))
                    .frame(height: buttonHeight - innerPadding)
                    .padding(.horizontal, innerPadding / 2)
                    .mask {
                        RoundedRectangle(cornerRadius: buttonHeight / 2)
                            .frame(height: buttonHeight - innerPadding)
                            .padding(.horizontal, innerPadding / 2)
                    }

                // Title text
                Text(title)
                    .bold()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .opacity(Double(1.0 - (offset / (geometry.size.width - buttonHeight))))

                // Sliding circle
                Circle()
                    .fill(accentColor)
                    .frame(width: buttonHeight - innerPadding, height: buttonHeight - innerPadding)
                    .overlay(
                        ZStack {
                            if isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Image(systemName: "arrow.right")
                                    .foregroundColor(.white)
                                    .opacity(Double(1.0 - (offset / (geometry.size.width / 2))))

                                Image(systemName: "checkmark")
                                    .foregroundColor(.white)
                                    .opacity(Double(max(0, (offset - geometry.size.width / 2) / (geometry.size.width / 2))))
                            }
                        }
                    )
                    .offset(x: max(0, min(offset, geometry.size.width - buttonHeight)))
                    .padding(.horizontal, innerPadding / 2)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard !isLoading else { return }
                                withAnimation(.interactiveSpring()) {
                                    isDragging = true
                                    offset = value.translation.width
                                }
                            }
                            .onEnded { _ in
                                guard !isLoading else { return }
                                isDragging = false
                                withAnimation(.spring()) {
                                    let threshold = geometry.size.width * 0.7
                                    if offset > threshold {
                                        Haptics.play(.medium)
                                        offset = geometry.size.width - buttonHeight
                                        isLoading = true
                                        Task { @MainActor in
                                            do {
                                                try await onComplete()
                                            } catch {
                                                // Reset the slider back to the start on error
                                                withAnimation(.spring(duration: 0.3)) {
                                                    offset = 0
                                                }

                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {  // Adjust the delay to match animation duration
                                                    isLoading = false
                                                }
                                            }
                                        }
                                    } else {
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
    VStack(spacing: 20) {
        Spacer()

        SwipeButton(
            title: "Swipe To Pay",
            accentColor: .greenAccent
        ) {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            throw NSError(domain: "com.bitkit.test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test error"])
        }

        SwipeButton(
            title: "Slide To Confirm",
            accentColor: .blueAccent
        ) {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            throw NSError(domain: "com.bitkit.test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test error"])
        }

        SwipeButton(
            title: "Swipe To Transfer",
            accentColor: .purpleAccent
        ) {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            throw NSError(domain: "com.bitkit.test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test error"])
        }

        Spacer()
    }
    .padding()
    .preferredColorScheme(.dark)
}
