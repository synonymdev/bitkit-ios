import SwiftUI

/// A small pill button with an optional icon, used for "Add Link", "Add Tag" and suggestion pills.
struct IconActionButton: View {
    let icon: String?
    let isSystemIcon: Bool
    let title: String
    let tint: Color
    let accessibilityId: String
    let action: () -> Void

    init(
        icon: String? = nil,
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
                if let icon {
                    iconImage(icon)
                        .frame(width: 16, height: 16)
                }

                CaptionBText(title, textColor: tint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(ButtonGradient())
            .cornerRadius(64)
            .shadow(color: .white10, radius: 0, x: 0, y: -1)
            .shadow(color: .black.opacity(0.32), radius: 2, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityId)
    }

    @ViewBuilder
    private func iconImage(_ icon: String) -> some View {
        if isSystemIcon {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(tint)
        } else {
            Image(icon)
                .resizable()
                .scaledToFit()
                .foregroundColor(tint)
        }
    }
}
