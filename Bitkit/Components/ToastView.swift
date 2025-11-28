import SwiftUI

struct ToastView: View {
    let toast: Toast
    let onDismiss: () -> Void
    let onDragStart: () -> Void
    let onDragEnd: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var hasPausedAutoHide = false
    private let dismissThreshold: CGFloat = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            BodyMSBText(toast.title, textColor: accentColor)

            if let description = toast.description {
                CaptionText(description, textColor: .textPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(accentColor.opacity(0.32))
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 25)
        .accessibilityIdentifierIfPresent(toast.accessibilityIdentifier)
        .overlay(alignment: .topTrailing) {
            if !toast.autoHide {
                Button(action: onDismiss) {
                    Image("x-mark")
                        .resizable()
                        .frame(width: 16, height: 16)
                        .foregroundColor(.textSecondary)
                }
                .accessibilityLabel("Dismiss toast")
                .padding(16)
                .contentShape(Rectangle())
            }
        }
        .offset(y: dragOffset)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // Allow both upward and downward drag, but limit downward drag
                    let translation = value.translation.height
                    if translation < 0 {
                        // Upward drag - allow freely
                        dragOffset = translation
                    } else {
                        // Downward drag - apply resistance
                        dragOffset = translation * 0.08
                    }

                    // Pause auto-hide when drag starts (only once)
                    if abs(translation) > 5 && !hasPausedAutoHide {
                        hasPausedAutoHide = true
                        onDragStart()
                    }
                }
                .onEnded { value in
                    // Resume auto-hide when drag ends (if we paused it)
                    if hasPausedAutoHide {
                        hasPausedAutoHide = false
                        onDragEnd()
                    }

                    // Dismiss if swiped up enough, otherwise snap back
                    if value.translation.height < -dismissThreshold {
                        withAnimation(.easeOut(duration: 0.3)) {
                            dragOffset = -200
                        }

                        // Dismiss after animation
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: UInt64(0.3 * 1_000_000_000))
                            onDismiss()
                        }
                    } else {
                        // Snap back to original position
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            dragOffset = 0
                        }
                    }
                }
        )
    }

    private var accentColor: Color {
        switch toast.type {
        case .success: return .greenAccent
        case .info: return .blueAccent
        case .lightning: return .purpleAccent
        case .warning: return .brandAccent
        case .error: return .redAccent
        }
    }
}

#Preview {
    ToastView(
        toast: .init(
            type: .info,
            title: "Hey toast",
            description: "This is a toast message",
            autoHide: true,
            visibilityTime: 4.0,
            accessibilityIdentifier: nil
        ),
        onDismiss: {},
        onDragStart: {},
        onDragEnd: {}
    )
    .preferredColorScheme(.dark)
}
