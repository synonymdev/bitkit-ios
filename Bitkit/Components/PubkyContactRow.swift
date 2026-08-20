import SwiftUI

struct PubkyContactRow: View {
    let contact: PubkyContact
    var verticalPadding: CGFloat = 12
    var showsDivider = true
    var isLoading = false
    var isSelected = false
    var selectionColor: Color = .brandAccent
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
                    } else if isSelected {
                        Image("check-mark")
                            .resizable()
                            .scaledToFit()
                            .foregroundColor(selectionColor)
                            .frame(width: 24, height: 24)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.vertical, verticalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .accessibilityLabel(contact.displayName)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if showsDivider {
                CustomDivider()
            }
        }
    }
}
