import SwiftUI

struct ContactImportOverviewView: View {
    let profile: PubkyProfile
    let contacts: [PubkyContact]

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var pubkyProfile: PubkyProfileManager

    @State private var isImporting = false

    private enum AvatarLayout {
        static let size: CGFloat = 32
        static let overlap: CGFloat = 8
        static let step = size - overlap
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("contacts__import_nav_title"))
                .padding(.horizontal, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    DisplayText(
                        t("contacts__import_found_title"),
                        accentColor: .pubkyGreen
                    )
                    .padding(.top, 24)
                    .padding(.bottom, 8)

                    BodyMText(
                        t("contacts__import_found_description", variables: ["key": profile.truncatedPublicKey]),
                        accentColor: .white,
                        accentFont: Fonts.bold
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 32)

                    profileRow
                        .padding(.bottom, 24)

                    contactsSummary
                }
                .padding(.horizontal, 16)
            }

            Spacer()

            BottomActionBar {
                buttonBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSafeAreaPadding()
        .background(Color.customBlack)
        .navigationBarHidden(true)
    }

    // MARK: - Profile Row

    private var profileRow: some View {
        HStack(alignment: .top, spacing: 16) {
            HeadlineText(profile.name)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if let imageUrl = profile.imageUrl {
                    PubkyImage(uri: imageUrl, size: 64)
                } else {
                    ContactAvatarLetter(source: profile.name, size: 64, backgroundColor: .pubkyGreen)
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityIdentifier("ContactImportOverviewProfile")
    }

    // MARK: - Contacts Summary

    private var contactsSummary: some View {
        HStack(spacing: 16) {
            BodyMSBText(t("contacts__import_friends_count", variables: ["count": "\(contacts.count)"]))

            Spacer()

            avatarStack
        }
        .accessibilityIdentifier("ContactImportOverviewSummary")
    }

    @ViewBuilder
    private var avatarStack: some View {
        let displayContacts = Array(contacts.prefix(5))
        let overflow = contacts.count - displayContacts.count
        let avatarCount = displayContacts.count + (overflow > 0 ? 1 : 0)

        ZStack(alignment: .leading) {
            ForEach(Array(displayContacts.enumerated()), id: \.element.id) { index, contact in
                contactImportAvatar(contact)
                    .offset(x: CGFloat(index) * AvatarLayout.step)
            }

            if overflow > 0 {
                Circle()
                    .fill(Color(hex: 0x05050A))
                    .frame(width: AvatarLayout.size, height: AvatarLayout.size)
                    .overlay {
                        AccentedText(
                            "+\(overflow)",
                            font: Fonts.medium(size: 14),
                            fontColor: .textPrimary
                        )
                    }
                    .overlay(
                        Circle()
                            .strokeBorder(Color(hex: 0x89898F), lineWidth: 1)
                    )
                    .contactImportAvatarShadow()
                    .offset(x: CGFloat(displayContacts.count) * AvatarLayout.step)
            }
        }
        .frame(
            width: CGFloat(max(avatarCount - 1, 0)) * AvatarLayout.step + AvatarLayout.size,
            height: AvatarLayout.size,
            alignment: .leading
        )
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func contactImportAvatar(_ contact: PubkyContact) -> some View {
        if let imageUrl = contact.profile.imageUrl {
            PubkyImage(uri: imageUrl, size: AvatarLayout.size)
                .contactImportAvatarShadow()
        } else {
            ContactAvatarLetter(
                source: contact.displayName,
                size: AvatarLayout.size,
                backgroundColor: Color(hex: 0x303034),
                textFont: Fonts.medium(size: 14)
            )
            .contactImportAvatarShadow()
        }
    }

    // MARK: - Button Bar

    private var buttonBar: some View {
        HStack(spacing: 16) {
            CustomButton(title: t("contacts__import_select"), variant: .secondary) {
                navigation.navigate(.contactImportSelect)
            }
            .accessibilityIdentifier("ContactImportOverviewSelect")

            CustomButton(
                title: t("contacts__import_all"),
                isLoading: isImporting
            ) {
                await importAllContacts()
            }
            .accessibilityIdentifier("ContactImportOverviewImportAll")
        }
    }

    // MARK: - Actions

    private func importAllContacts() async {
        isImporting = true
        defer { isImporting = false }

        do {
            try await contactsManager.importContacts(publicKeys: contacts.map(\.publicKey))
            contactsManager.clearPendingImport()
            navigation.path = [.payContacts]
        } catch {
            app.toast(type: .error, title: t("contacts__import_error"))
        }
    }
}

private extension View {
    func contactImportAvatarShadow() -> some View {
        shadow(color: Color(hex: 0x05050A).opacity(0.25), radius: 3, x: 0, y: 1)
            .shadow(color: Color(hex: 0x05050A).opacity(0.25), radius: 2, x: 0, y: 1)
    }
}

#Preview {
    let profile = PubkyProfile(
        publicKey: "pubky1abc123def456",
        name: "Satoshi",
        bio: "Building the future",
        imageUrl: nil,
        links: [],
        status: nil
    )
    let contacts = [
        PubkyContact(publicKey: "pubky1aaa111", profile: PubkyProfile(
            publicKey: "pubky1aaa111", name: "Alice", bio: "", imageUrl: nil, links: [], status: nil
        )),
        PubkyContact(publicKey: "pubky1bbb222", profile: PubkyProfile(
            publicKey: "pubky1bbb222", name: "Bob", bio: "", imageUrl: nil, links: [], status: nil
        )),
        PubkyContact(publicKey: "pubky1ccc333", profile: PubkyProfile(
            publicKey: "pubky1ccc333", name: "Carol", bio: "", imageUrl: nil, links: [], status: nil
        )),
    ]

    NavigationStack {
        ContactImportOverviewView(profile: profile, contacts: contacts)
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(ContactsManager())
            .environmentObject(PubkyProfileManager())
    }
    .preferredColorScheme(.dark)
}
