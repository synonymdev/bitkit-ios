import SwiftUI

/// Card row on the Pubky Choice screen: a pubky from Pubky Ring, or the "create in Bitkit" option.
struct PubkyChoiceRow: View {
    var icon: String?
    var systemIcon: String?
    let caption: String
    let title: String
    var avatarName: String?
    var avatarImageUrl: String?
    let accessibilityId: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                CircularIcon(icon: iconView, backgroundColor: .black, size: 40)

                VStack(alignment: .leading, spacing: 0) {
                    CaptionText(caption.localizedUppercase, textColor: .white64)
                        .lineLimit(1)

                    BodyMSBText(title, textColor: .white)
                        .lineLimit(1)
                }

                Spacer()

                if let avatarName {
                    PubkyContactAvatar(name: avatarName, imageUrl: avatarImageUrl, size: 32)
                }
            }
            .padding(16)
            .background(Color.gray6)
            .cornerRadius(16)
        }
        .accessibilityIdentifier(accessibilityId)
    }

    private var iconView: some View {
        Group {
            if let icon {
                Image(icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
            } else if let systemIcon {
                Image(systemName: systemIcon)
                    .font(.system(size: 16, weight: .semibold))
            }
        }
        .foregroundColor(.pubkyGreen)
    }
}
