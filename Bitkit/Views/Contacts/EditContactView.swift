import SwiftUI

struct EditContactView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var contactsManager: ContactsManager

    let publicKey: String

    @State private var name: String = ""
    @State private var bio: String = ""
    @State private var imageUrl: String?
    @State private var links: [ProfileLinkInput] = []
    @State private var tags: [String] = []
    @State private var isSaving = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("contacts__edit_title"))
                .padding(.horizontal, 16)

            ProfileEditFormView(
                name: $name,
                bio: $bio,
                links: $links,
                tags: $tags,
                publicKey: publicKey,
                isSaving: isSaving,
                footerNote: nil,
                deleteLabel: t("contacts__delete_label"),
                onSave: { await saveContact() },
                onCancel: { navigation.navigateBack() },
                onDelete: { showDeleteConfirmation = true }
            ) {
                avatarSection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .bottomSafeAreaPadding()
        .background(Color.customBlack)
        .navigationBarHidden(true)
        .task {
            loadContactData()
        }
        .alert(t("contacts__delete_title", variables: ["name": name]), isPresented: $showDeleteConfirmation) {
            Button(t("contacts__delete_confirm"), role: .destructive) {
                Task { await deleteContact() }
            }
            Button(t("common__dialog_cancel"), role: .cancel) {}
        } message: {
            Text(t("contacts__delete_description"))
        }
    }

    // MARK: - Avatar

    @ViewBuilder
    private var avatarSection: some View {
        Group {
            if let imageUrl {
                PubkyImage(uri: imageUrl, size: 100)
            } else {
                Circle()
                    .fill(Color.gray5)
                    .frame(width: 100, height: 100)
                    .overlay {
                        Image("user-square")
                            .resizable()
                            .scaledToFit()
                            .foregroundColor(.white32)
                            .frame(width: 50, height: 50)
                    }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Data Loading

    private func loadContactData() {
        guard let contact = contactsManager.contacts.first(where: { $0.publicKey == publicKey }) else { return }
        let profile = contact.profile
        name = profile.name
        bio = profile.bio
        imageUrl = profile.imageUrl
        links = profile.links.map { ProfileLinkInput(label: $0.label, url: $0.url) }
        tags = profile.tags
    }

    // MARK: - Delete

    private func deleteContact() async {
        do {
            try await contactsManager.removeContact(publicKey: publicKey)
            app.toast(type: .success, title: t("contacts__delete_success"))
            navigation.path = [.contacts]
        } catch {
            Logger.error("Failed to delete contact: \(error)", context: "EditContactView")
            app.toast(type: .error, title: t("contacts__delete_error"))
        }
    }

    // MARK: - Save

    private func saveContact() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        isSaving = true
        defer { isSaving = false }

        do {
            try await contactsManager.updateContact(
                publicKey: publicKey,
                name: trimmedName,
                bio: bio.trimmingCharacters(in: .whitespacesAndNewlines),
                imageUrl: imageUrl,
                links: links.map { PubkyProfileLink(label: $0.label, url: $0.url) },
                tags: tags
            )
            app.toast(type: .success, title: t("contacts__edit_saved"))
            navigation.navigateBack()
        } catch {
            Logger.error("Failed to save contact: \(error)", context: "EditContactView")
            app.toast(type: .error, title: t("contacts__edit_error"))
        }
    }
}

#Preview {
    NavigationStack {
        EditContactView(publicKey: "z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK")
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(ContactsManager())
    }
    .preferredColorScheme(.dark)
}
