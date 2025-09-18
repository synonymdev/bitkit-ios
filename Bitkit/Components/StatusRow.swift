import SwiftUI

struct StatusRow: View {
    let imageName: String
    let title: String
    let description: String
    let status: HealthStatus
    let onTap: (() -> Void)?

    init(
        imageName: String,
        title: String,
        description: String,
        status: HealthStatus,
        onTap: (() -> Void)? = nil
    ) {
        self.imageName = imageName
        self.title = title
        self.description = description
        self.status = status
        self.onTap = onTap
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                CircularIcon(
                    icon: imageName,
                    iconColor: status.iconColor,
                    backgroundColor: status.iconBackground,
                    size: 32
                )

                VStack(alignment: .leading, spacing: 0) {
                    BodyMSBText(title)
                    CaptionBText(description)
                }

                Spacer()
            }

            Divider()
                .padding(.top, 16)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
    }
}
