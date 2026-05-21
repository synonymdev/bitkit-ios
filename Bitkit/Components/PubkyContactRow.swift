import SwiftUI

struct PubkyContactRow: View {
    let contact: PubkyContact
    var verticalPadding: CGFloat = 12
    var showsDivider = true
    var isLoading = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 16) {
                    PubkyContactAvatar(contact: contact, size: 48)

                    VStack(alignment: .leading, spacing: 4) {
                        CaptionText(contact.profile.truncatedPublicKey.localizedUppercase)
                            .lineLimit(1)

                        BodyMSBText(contact.displayName)
                            .lineLimit(1)
                    }

                    Spacer()

                    if isLoading {
                        ProgressView()
                    }
                }
                .padding(.vertical, verticalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .accessibilityLabel(contact.displayName)

            if showsDivider {
                CustomDivider()
            }
        }
    }
}
