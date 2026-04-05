import SwiftUI

/// A circular button with a gradient background, used for action icons (copy, share, edit, delete).
struct GradientCircleButton: View {
    let icon: String?
    let systemIcon: String?
    let accessibilityLabel: String
    let action: () -> Void

    init(icon: String, accessibilityLabel: String, action: @escaping () -> Void) {
        self.icon = icon
        systemIcon = nil
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    init(systemIcon: String, accessibilityLabel: String, action: @escaping () -> Void) {
        icon = nil
        self.systemIcon = systemIcon
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.gray5, .gray6],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white10, lineWidth: 1)
                            .padding(0.5)
                    )

                if let icon {
                    Image(icon)
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(.textPrimary)
                        .frame(width: 24, height: 24)
                } else if let systemIcon {
                    Image(systemName: systemIcon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.textPrimary)
                }
            }
            .frame(width: 48, height: 48)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}
