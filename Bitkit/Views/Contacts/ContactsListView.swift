import SwiftUI

struct ContactsListView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager
    @EnvironmentObject var contactsManager: ContactsManager

    @State private var searchText = ""
    @State private var showAddContactSheet = false

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("contacts__nav_title"))
                .padding(.horizontal, 16)

            searchAndAddBar
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)

            Group {
                if contactsManager.isLoading && contactsManager.contacts.isEmpty {
                    loadingContent
                } else if contactsManager.contacts.isEmpty, let errorMessage = contactsManager.loadErrorMessage {
                    errorContent(message: errorMessage)
                } else if contactsManager.contacts.isEmpty && !contactsManager.isLoading && !isSearching {
                    emptyContent
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if !isSearching, pubkyProfile.isAuthenticated, let profile = pubkyProfile.profile {
                                myProfileSection(profile)
                            }

                            contactsList
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.customBlack)
        .navigationBarHidden(true)
        .task {
            await loadContacts()
        }
        .sheet(isPresented: $showAddContactSheet) {
            AddContactSheet(
                currentPublicKey: pubkyProfile.publicKey,
                onAdd: { pubky in
                    navigation.navigate(.addContact(publicKey: pubky))
                },
                onScanQR: {
                    navigation.navigate(.scanner)
                }
            )
        }
    }

    // MARK: - Search Bar + Add Button

    @ViewBuilder
    private var searchAndAddBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image("magnifying-glass")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.white50)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)

                TextField(t("common__search"), text: $searchText, backgroundColor: .clear, font: Fonts.regular(size: 17))
                    .foregroundColor(.textPrimary)
                    .accessibilityLabel(t("common__search"))
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(Color.gray6)
            .clipShape(Capsule())

            Button {
                showAddContactSheet = true
            } label: {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.gray5, .gray6],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.white10, lineWidth: 1)
                                .padding(0.5)
                        )

                    Image("plus")
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(.textPrimary)
                        .frame(width: 20, height: 20)
                }
                .frame(width: 48, height: 48)
            }
            .accessibilityLabel(t("contacts__add_button"))
            .accessibilityIdentifier("ContactsAddButton")
        }
    }

    // MARK: - My Profile Section

    @ViewBuilder
    private func myProfileSection(_ profile: PubkyProfile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(t("contacts__my_profile"))

            contactRow(
                name: profile.name,
                truncatedKey: profile.truncatedPublicKey,
                imageUrl: profile.imageUrl
            ) {
                navigation.navigate(.profile)
            }
            .accessibilityIdentifier("ContactsMyProfile")

            CustomDivider()
        }
    }

    // MARK: - Contacts List

    @ViewBuilder
    private var contactsList: some View {
        if !filteredContacts.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(t("contacts__nav_title").localizedUppercase)
                CustomDivider()

                ForEach(filteredContacts) { contact in
                    contactRow(
                        name: contact.displayName,
                        truncatedKey: contact.profile.truncatedPublicKey,
                        imageUrl: contact.profile.imageUrl
                    ) {
                        navigation.navigate(.contactDetail(publicKey: contact.publicKey))
                    }
                    .accessibilityIdentifier("Contact_\(contact.publicKey)")

                    CustomDivider()
                }
            }
        }
    }

    // MARK: - Section Header

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        CaptionMText(title, textColor: .white64)
            .padding(.vertical, 16)
    }

    // MARK: - Contact Row

    @ViewBuilder
    private func contactRow(name: String, truncatedKey: String, imageUrl: String?, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                contactAvatar(name: name, imageUrl: imageUrl)

                VStack(alignment: .leading, spacing: 4) {
                    CaptionText(truncatedKey)

                    BodyMSBText(name)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.vertical, 12)
        }
        .accessibilityLabel(name)
    }

    @ViewBuilder
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

    // MARK: - Filtered Contacts

    private var filteredContacts: [PubkyContact] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return contactsManager.contacts }

        let query = trimmed.lowercased()
        return contactsManager.contacts.filter {
            $0.displayName.lowercased().contains(query) ||
                $0.publicKey.lowercased().contains(query)
        }
    }

    // MARK: - Loading & Empty States

    @ViewBuilder
    private var loadingContent: some View {
        VStack {
            Spacer()
            ActivityIndicator(size: 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func errorContent(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()

            BodyMText(t("contacts__error_loading"))

            if message != t("contacts__error_loading") {
                BodySText(message, textColor: .white64)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }

            CustomButton(title: t("profile__retry_load"), variant: .secondary) {
                await loadContacts()
            }
            .accessibilityIdentifier("ContactsRetry")

            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyContent: some View {
        VStack(spacing: 0) {
            if pubkyProfile.isAuthenticated, let profile = pubkyProfile.profile {
                VStack(alignment: .leading, spacing: 0) {
                    myProfileSection(profile)
                        .padding(.horizontal, 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 16) {
                CustomButton(title: t("contacts__intro_add_contact")) {
                    showAddContactSheet = true
                }
                .accessibilityIdentifier("ContactsEmptyAddButton")

                BodyMText(t("contacts__empty_state"), textColor: .white64)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 32)
            .padding(.top, 48)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadContacts() async {
        guard let pk = pubkyProfile.publicKey else { return }

        do {
            try await contactsManager.loadContacts(for: pk)
        } catch {
            Logger.error("Failed to load contacts in view: \(error)", context: "ContactsListView")

            if !contactsManager.contacts.isEmpty {
                app.toast(
                    type: .error,
                    title: t("contacts__error_loading"),
                    description: error.localizedDescription
                )
            }
        }
    }
}

#Preview {
    NavigationStack {
        ContactsListView()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(PubkyProfileManager())
            .environmentObject(ContactsManager())
    }
    .preferredColorScheme(.dark)
}
