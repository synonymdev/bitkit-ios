import SwiftUI

struct CenteredProfileHeader: View {
    let truncatedKey: String
    let name: String
    let bio: String
    let imageUrl: String?
    var avatarSize: CGFloat = 100
    var showBio: Bool = true
    var showDivider: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            CaptionMText(truncatedKey, textColor: .white64)
                .padding(.bottom, 16)

            avatarView
                .padding(.bottom, 16)

            Text(name.uppercased())
                .font(Fonts.black(size: 44))
                .kerning(-1)
                .foregroundColor(.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, showBio && !bio.isEmpty ? 8 : 0)

            if showBio, !bio.isEmpty {
                BodyMText(bio, textColor: .white64)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 16)
            }

            if showDivider {
                CustomDivider()
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var avatarView: some View {
        if let imageUrl {
            PubkyImage(uri: imageUrl, size: avatarSize)
        } else {
            Circle()
                .fill(Color.gray5)
                .frame(width: avatarSize, height: avatarSize)
                .overlay {
                    Image("user-square")
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(.white32)
                        .frame(width: avatarSize * 0.5, height: avatarSize * 0.5)
                }
        }
    }
}

#Preview {
    VStack {
        CenteredProfileHeader(
            truncatedKey: "3RSD...W5XG",
            name: "Satoshi Nakamoto",
            bio: "Authored the Bitcoin white paper, developed Bitcoin, mined first block.",
            imageUrl: nil
        )

        Spacer()
    }
    .padding(.horizontal, 16)
    .background(Color.customBlack)
    .preferredColorScheme(.dark)
}
