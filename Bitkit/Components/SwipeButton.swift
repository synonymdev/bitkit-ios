import SwiftUI

struct SwipeButton: View {
    let title: String
    let accentColor: Color
    /// Optional binding for swipe progress (0...1), e.g. to drive animations in the parent.
    var swipeProgress: Binding<CGFloat>?
    let onComplete: () async throws -> Void

    @State private var offset: CGFloat = 0
    @State private var isLoading = false

    private let buttonHeight: CGFloat = 76
    private let innerPadding: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let maxOffset = max(1, geometry.size.width - buttonHeight)
            let clampedOffset = max(0, min(offset, geometry.size.width - buttonHeight))
            let trailWidth = max(0, min(clampedOffset + (buttonHeight - innerPadding), geometry.size.width - innerPadding))
            let textProgress = offset / maxOffset
            let halfWidth = geometry.size.width / 2

            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: buttonHeight / 2)
                    .fill(backgroundGradient)

                // Colored trail
                RoundedRectangle(cornerRadius: buttonHeight / 2)
                    .fill(accentColor.opacity(0.2))
                    .frame(width: trailWidth)
                    .frame(height: buttonHeight - innerPadding)
                    .padding(.horizontal, innerPadding / 2)
                    .mask {
                        RoundedRectangle(cornerRadius: buttonHeight / 2)
                            .frame(height: buttonHeight - innerPadding)
                            .padding(.horizontal, innerPadding / 2)
                    }

                // Track text
                BodySSBText(title)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .opacity(Double(1.0 - textProgress))

                // Knob
                Circle()
                    .fill(accentColor)
                    .frame(width: buttonHeight - innerPadding, height: buttonHeight - innerPadding)
                    .overlay(
                        ZStack {
                            if isLoading {
                                ActivityIndicator(theme: .dark)
                            } else {
                                Image("arrow-right")
                                    .resizable()
                                    .frame(width: 24, height: 24)
                                    .foregroundColor(.gray7)
                                    .opacity(Double(1.0 - (offset / halfWidth)))

                                Image("check-mark")
                                    .resizable()
                                    .frame(width: 32, height: 32)
                                    .foregroundColor(.gray7)
                                    .opacity(Double(max(0, (offset - halfWidth) / halfWidth)))
                            }
                        }
                    )
                    .accessibilityIdentifier("GRAB")
                    .offset(x: clampedOffset)
                    .padding(.horizontal, innerPadding / 2)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard !isLoading else { return }
                                withAnimation(.interactiveSpring()) {
                                    offset = value.translation.width
                                    swipeProgress?.wrappedValue = max(0, min(1, offset / maxOffset))
                                }
                            }
                            .onEnded { _ in
                                guard !isLoading else { return }
                                withAnimation(.spring()) {
                                    let threshold = geometry.size.width * 0.7
                                    if offset > threshold {
                                        Haptics.play(.medium)
                                        offset = geometry.size.width - buttonHeight
                                        swipeProgress?.wrappedValue = 1
                                        isLoading = true
                                        Task { @MainActor in
                                            do {
                                                try await onComplete()
                                            } catch {
                                                // Reset the slider back to the start on error
                                                withAnimation(.spring(duration: 0.3)) {
                                                    offset = 0
                                                    swipeProgress?.wrappedValue = 0
                                                }

                                                // Adjust the delay to match animation duration
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                                    isLoading = false
                                                }
                                            }
                                        }
                                    } else {
                                        offset = 0
                                        swipeProgress?.wrappedValue = 0
                                    }
                                }
                            }
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: buttonHeight)
    }

    private var backgroundGradient: LinearGradient {
        let colors: [Color] = [Color(hex: 0x2A2A2A), Color(hex: 0x1C1C1C)]
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
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
