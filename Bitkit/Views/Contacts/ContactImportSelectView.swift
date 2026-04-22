import SwiftUI

struct ContactImportSelectView: View {
    let contacts: [PubkyContact]

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var contactsManager: ContactsManager

    @State private var selectedKeys: Set<String> = []
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("contacts__import_nav_title"))
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 8) {
                DisplayText(
                    t("contacts__import_select_title"),
                    accentColor: .pubkyGreen
                )

                BodyMText(t("contacts__import_select_description"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 16)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(contacts) { contact in
                        contactSelectRow(contact)
                        CustomDivider()
                            .padding(.leading, 72)
                    }
                }
                .padding(.horizontal, 16)
            }

            footerBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSafeAreaPadding()
        .background(Color.customBlack)
        .navigationBarHidden(true)
        .task {
            selectedKeys = Set(contacts.map(\.publicKey))
        }
    }

    // MARK: - Contact Select Row

    @ViewBuilder
    private func contactSelectRow(_ contact: PubkyContact) -> some View {
        let isSelected = selectedKeys.contains(contact.publicKey)

        Button {
            if isSelected {
                selectedKeys.remove(contact.publicKey)
            } else {
                selectedKeys.insert(contact.publicKey)
            }
        } label: {
            HStack(spacing: 16) {
                contactAvatar(name: contact.displayName, imageUrl: contact.profile.imageUrl)

                VStack(alignment: .leading, spacing: 4) {
                    CaptionText(contact.profile.truncatedPublicKey)

                    BodyMSBText(contact.displayName)
                        .lineLimit(1)
                }

                Spacer()

                checkmark(isSelected: isSelected)
            }
            .padding(.vertical, 12)
        }
        .accessibilityLabel(contact.displayName)
        .accessibilityIdentifier("ContactImportSelect_\(contact.publicKey)")
    }

    // MARK: - Checkmark

    private func checkmark(isSelected: Bool) -> some View {
        ZStack {
            if isSelected {
                Circle()
                    .fill(Color.pubkyGreen)
                    .frame(width: 24, height: 24)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }
            } else {
                Circle()
                    .stroke(Color.white32, lineWidth: 1.5)
                    .frame(width: 24, height: 24)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Contact Avatar

    private func contactAvatar(name: String, imageUrl: String?) -> some View {
        Group {
            if let imageUrl {
                PubkyImage(uri: imageUrl, size: 48)
            } else {
                Circle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 48, height: 48)
                    .overlay {
                        Text(String(name.prefix(1)).uppercased())
                            .font(Fonts.bold(size: 17))
                            .foregroundColor(.textPrimary)
                    }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Footer Bar

    private var footerBar: some View {
        VStack(spacing: 0) {
            CustomDivider()

            HStack(spacing: 12) {
                BodySText(t("contacts__import_selected_count", variables: ["count": "\(selectedKeys.count)"]))

                Spacer()

                pillButton(title: t("contacts__import_select_all"), isActive: selectedKeys.count == contacts.count) {
                    selectedKeys = Set(contacts.map(\.publicKey))
                }
                .accessibilityIdentifier("ContactImportSelectAll")

                pillButton(title: t("contacts__import_select_none"), isActive: selectedKeys.isEmpty) {
                    selectedKeys = []
                }
                .accessibilityIdentifier("ContactImportSelectNone")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            CustomButton(
                title: t("common__continue"),
                isLoading: isImporting
            ) {
                await importSelectedContacts()
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 16)
            .accessibilityIdentifier("ContactImportSelectContinue")
        }
    }

    // MARK: - Pill Button

    private func pillButton(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Fonts.medium(size: 13))
                .foregroundColor(isActive ? .white64 : .textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isActive ? Color.white.opacity(0.05) : Color.white.opacity(0.1))
                )
                .overlay(
                    Capsule()
                        .stroke(Color.white10, lineWidth: 1)
                )
        }
        .disabled(isActive)
        .accessibilityLabel(title)
    }

    // MARK: - Actions

    private func importSelectedContacts() async {
        let selected = contacts.filter { selectedKeys.contains($0.publicKey) }

        guard !selected.isEmpty else {
            contactsManager.clearPendingImport()
            navigation.path = [.payContacts]
            return
        }

        isImporting = true
        defer { isImporting = false }

        do {
            try await contactsManager.importContacts(publicKeys: selected.map(\.publicKey))
            contactsManager.clearPendingImport()
            navigation.path = [.payContacts]
        } catch {
            app.toast(type: .error, title: t("contacts__import_error"))
        }
    }
}

#Preview {
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
        PubkyContact(publicKey: "pubky1ddd444", profile: PubkyProfile(
            publicKey: "pubky1ddd444", name: "Dave", bio: "", imageUrl: nil, links: [], status: nil
        )),
        PubkyContact(publicKey: "pubky1eee555", profile: PubkyProfile(
            publicKey: "pubky1eee555", name: "Eve", bio: "", imageUrl: nil, links: [], status: nil
        )),
    ]

    NavigationStack {
        ContactImportSelectView(contacts: contacts)
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(ContactsManager())
    }
    .preferredColorScheme(.dark)
}
