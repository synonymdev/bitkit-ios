import SwiftUI

struct ProfileEditFormView<Avatar: View>: View {
    enum DeleteActionStyle {
        case buttonWithIcon
        case textOnly
    }

    @Binding var name: String
    @Binding var bio: String
    @Binding var links: [ProfileLinkInput]
    @Binding var tags: [String]

    let publicKey: String
    let publicKeyLabel: String
    let bioPlaceholder: String
    let isSaving: Bool
    let footerNote: String?
    let deleteLabel: String?
    let deleteActionStyle: DeleteActionStyle
    let onSave: () async -> Void
    let onCancel: () -> Void
    let onDelete: (() -> Void)?
    @ViewBuilder let avatar: () -> Avatar

    @State private var showAddLinkSheet = false
    @State private var showAddTagSheet = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 32) {
                        avatar()

                        ProfileNameField(name: $name, accessibilityId: "ProfileEditName")

                        CustomDivider()

                        pubkyKeySection
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 32)

                    VStack(alignment: .leading, spacing: 16) {
                        CustomDivider()

                        bioSection

                        CustomDivider()

                        linksSection

                        CustomDivider()

                        tagsSection

                        if let footerNote {
                            CustomDivider()

                            footnoteSection(footerNote)
                        }

                        if let deleteLabel, let onDelete {
                            CustomDivider()

                            deleteSection(label: deleteLabel, action: onDelete)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, ScreenLayout.floatingFooterClearance + 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture {
                dismissKeyboard()
            }

            footerBar
        }
        .sheet(isPresented: $showAddLinkSheet, onDismiss: dismissKeyboard) {
            AddLinkSheet { label, url in
                links.append(ProfileLinkInput(label: label, url: url))
            }
        }
        .sheet(isPresented: $showAddTagSheet, onDismiss: dismissKeyboard) {
            AddProfileTagSheet { tag in
                tags.append(tag)
            }
        }
    }

    // MARK: - Pubky Key Section

    private var pubkyKeySection: some View {
        VStack(spacing: 8) {
            CaptionMText(publicKeyLabel, textColor: .white64)

            BodyMSBText(publicKey, textColor: .white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Bio Section

    private var bioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("profile__create_bio_label"), textColor: .white64)

            TextField(
                bioPlaceholder,
                text: $bio,
                axis: .vertical,
                testIdentifier: "ProfileEditBio"
            )
        }
    }

    // MARK: - Links Section

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(links.indices, id: \.self) { index in
                linkRow(index: index)
            }

            IconActionButton(
                icon: "link",
                isSystemIcon: true,
                title: t("profile__create_add_link"),
                accessibilityId: "ProfileEditAddLink"
            ) {
                dismissKeyboard()
                showAddLinkSheet = true
            }
        }
    }

    @ViewBuilder
    private func linkRow(index: Int) -> some View {
        let link = links[index]

        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(link.label, textColor: .white64)

            HStack {
                ZStack(alignment: .leading) {
                    if link.url.isEmpty {
                        SwiftUI.Text(t("profile__add_link_url_placeholder"))
                            .foregroundColor(.white32)
                            .font(.custom(Fonts.semiBold, size: 15))
                    }

                    SwiftUI.TextField(
                        "",
                        text: Binding(
                            get: { links[index].url },
                            set: { links[index].url = $0 }
                        )
                    )
                    .font(.custom(Fonts.semiBold, size: 15))
                    .foregroundColor(.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ProfileEditLink_\(index)")
                }

                Spacer()

                Button {
                    links.remove(at: index)
                } label: {
                    Image("trash")
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(.white50)
                        .frame(width: 16, height: 16)
                }
                .accessibilityIdentifier("ProfileEditLinkRemove_\(index)")
                .accessibilityLabel(t("common__delete"))
            }
            .padding(16)
            .background(Color.white10)
            .cornerRadius(8)
        }
    }

    // MARK: - Delete Section

    private func deleteSection(label: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("profile__edit_delete_section"), textColor: .white64)

            switch deleteActionStyle {
            case .buttonWithIcon:
                IconActionButton(
                    icon: "trash",
                    title: label,
                    tint: .brandAccent,
                    accessibilityId: "ProfileEditDelete",
                    action: action
                )
            case .textOnly:
                Button(action: action) {
                    HStack {
                        BodySSBText(label, textColor: .redAccent)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier("ProfileEditDelete")
    }

    // MARK: - Footnote Section

    private func footnoteSection(_ note: String) -> some View {
        BodySText(note, textColor: .white64)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Tags Section

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tags.isEmpty {
                CaptionMText(t("profile__create_tags_label"), textColor: .white64)

                WrappingHStack(spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        Tag(tag, icon: .close, onDelete: {
                            tags.removeAll { $0 == tag }
                        })
                    }
                }
            }

            IconActionButton(
                icon: "tag",
                title: t("profile__create_add_tag"),
                accessibilityId: "ProfileEditAddTag"
            ) {
                dismissKeyboard()
                showAddTagSheet = true
            }
        }
    }

    private var footerBar: some View {
        HStack(spacing: 16) {
            CustomButton(title: t("common__cancel"), variant: .secondary) {
                onCancel()
            }
            .accessibilityIdentifier("ProfileEditCancel")

            CustomButton(
                title: t("common__save"),
                isLoading: isSaving
            ) {
                await onSave()
            }
            .accessibilityIdentifier("ProfileEditSave")
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .background(
            LinearGradient(colors: [.customBlack.opacity(0), .customBlack], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
