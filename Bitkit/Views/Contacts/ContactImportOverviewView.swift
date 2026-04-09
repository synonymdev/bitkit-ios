import SwiftUI

struct ContactImportOverviewView: View {
    let profile: PubkyProfile
    let contacts: [PubkyContact]

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var contactsManager: ContactsManager
    @EnvironmentObject var pubkyProfile: PubkyProfileManager

    @State private var isImporting = false

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
                        t("contacts__import_found_description", variables: ["key": profile.truncatedPublicKey])
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 32)

                    profileRow
                        .padding(.bottom, 24)

                    CustomDivider()

                    contactsSummary
                        .padding(.top, 24)
                }
                .padding(.horizontal, 32)
            }

            Spacer()

            buttonBar
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSafeAreaPadding()
        .background(Color.customBlack)
        .navigationBarHidden(true)
    }

    // MARK: - Profile Row

    @ViewBuilder
    private var profileRow: some View {
        HStack(alignment: .top, spacing: 16) {
            HeadlineText(profile.name)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if let imageUrl = profile.imageUrl {
                    PubkyImage(uri: imageUrl, size: 64)
                } else {
                    Circle()
                        .fill(Color.pubkyGreen)
                        .frame(width: 64, height: 64)
                        .overlay {
                            Text(String(profile.name.prefix(1)).uppercased())
                                .font(Fonts.bold(size: 22))
                                .foregroundColor(.textPrimary)
                        }
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityIdentifier("ContactImportOverviewProfile")
    }

    // MARK: - Contacts Summary

    @ViewBuilder
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
        let displayContacts = Array(contacts.prefix(4))
        let remaining = contacts.count - displayContacts.count
        HStack(spacing: -12) {
            ForEach(Array(displayContacts.enumerated()), id: \.element.id) { index, contact in
                Group {
                    if let imageUrl = contact.profile.imageUrl {
                        PubkyImage(uri: imageUrl, size: 40)
                    } else {
                        Circle()
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 40, height: 40)
                            .overlay {
                                Text(String(contact.displayName.prefix(1)).uppercased())
                                    .font(Fonts.bold(size: 15))
                                    .foregroundColor(.textPrimary)
                            }
                    }
                }
                .overlay(
                    Circle()
                        .stroke(Color.customBlack, lineWidth: 2)
                )
                .zIndex(Double(displayContacts.count - index))
            }

            if remaining > 0 {
                Circle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Text("+\(remaining)")
                            .font(Fonts.bold(size: 13))
                            .foregroundColor(.textPrimary)
                    }
                    .overlay(
                        Circle()
                            .stroke(Color.customBlack, lineWidth: 2)
                    )
                    .zIndex(0)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Button Bar

    @ViewBuilder
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
