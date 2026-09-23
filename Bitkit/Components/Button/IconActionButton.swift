import SwiftUI

/// A pill-shaped button with an icon and label, used for "Add Link", "Add Tag" actions.
struct IconActionButton: View {
    let icon: String
    let isSystemIcon: Bool
    let title: String
    let tint: Color
    let accessibilityId: String
    let action: () -> Void

    init(
        icon: String,
        isSystemIcon: Bool = false,
        title: String,
        tint: Color = .white,
        accessibilityId: String,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.isSystemIcon = isSystemIcon
        self.title = title
        self.tint = tint
        self.accessibilityId = accessibilityId
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isSystemIcon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(tint)
                } else {
                    Image(icon)
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(tint)
                        .frame(width: 14, height: 14)
                }

                BodySSBText(title, textColor: tint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(
                LinearGradient(
                    colors: [Color(hex: 0x2A2A2A), Color(hex: 0x1C1C1C)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 64)
                    .stroke(Color.white10, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.32), radius: 2, x: 0, y: 2)
            .cornerRadius(64)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityId)
    }
}
