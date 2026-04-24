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
        ScrollView {
            VStack(spacing: 0) {
                avatar()
                    .padding(.top, 24)
                    .padding(.bottom, 16)

                SwiftUI.TextField(
                    t("profile__create_name_placeholder"),
                    text: $name
                )
                .font(Fonts.black(size: 44))
                .kerning(-1)
                .textCase(.uppercase)
                .multilineTextAlignment(.center)
                .foregroundColor(.textPrimary)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .accessibilityIdentifier("ProfileEditName")

                CustomDivider()
                    .padding(.bottom, 16)

                pubkyKeySection
                    .padding(.bottom, 24)

                VStack(alignment: .leading, spacing: 0) {
                    bioSection
                        .padding(.bottom, 16)

                    linksSection
                        .padding(.bottom, 16)

                    if !links.isEmpty {
                        CustomDivider(color: .white16)
                            .padding(.bottom, 16)
                    }

                    tagsSection
                        .padding(.bottom, 24)

                    if let footerNote {
                        CustomDivider(color: .white16)
                            .padding(.bottom, 16)

                        footnoteSection(footerNote)
                            .padding(.bottom, 24)
                    }

                    if let deleteLabel, let onDelete {
                        CustomDivider(color: .white16)
                            .padding(.bottom, 16)

                        deleteSection(label: deleteLabel, action: onDelete)
                            .padding(.bottom, 24)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .onTapGesture {
            dismissKeyboard()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
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

    @ViewBuilder
    private var pubkyKeySection: some View {
        VStack(spacing: 8) {
            CaptionMText(publicKeyLabel, textColor: .white64)

            BodySText(
                publicKey,
                textColor: .white
            )
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Bio Section

    @ViewBuilder
    private var bioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("profile__create_bio_label"), textColor: .white64)

            TextField(
                bioPlaceholder,
                text: $bio,
                backgroundColor: .gray6,
                font: .custom(Fonts.regular, size: 17),
                axis: .vertical,
                testIdentifier: "ProfileEditBio"
            )
        }
    }

    // MARK: - Links Section

    @ViewBuilder
    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
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

        VStack(alignment: .leading, spacing: 4) {
            CaptionMText(link.label, textColor: .white64)

            HStack {
                ZStack(alignment: .leading) {
                    if link.url.isEmpty {
                        SwiftUI.Text(t("profile__add_link_url_placeholder"))
                            .foregroundColor(.white32)
                            .font(.custom(Fonts.regular, size: 17))
                    }

                    SwiftUI.TextField(
                        "",
                        text: Binding(
                            get: { links[index].url },
                            set: { links[index].url = $0 }
                        )
                    )
                    .font(.custom(Fonts.regular, size: 17))
                    .foregroundColor(.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ProfileEditLink_\(index)")
                }

                Spacer()

                Image(systemName: "pencil")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white50)
                    .accessibilityHidden(true)

                Button {
                    links.remove(at: index)
                } label: {
                    Image("trash")
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(.white50)
                        .frame(width: 18, height: 18)
                }
                .accessibilityIdentifier("ProfileEditLinkRemove_\(index)")
                .accessibilityLabel(t("common__delete"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.gray6)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white10, lineWidth: 1)
            )
            .cornerRadius(8)
        }
    }

    // MARK: - Delete Section

    @ViewBuilder
    private func deleteSection(label: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(t("profile__edit_delete_section"), textColor: .white64)

            switch deleteActionStyle {
            case .buttonWithIcon:
                CustomButton(
                    title: label,
                    size: .small,
                    icon: Image("trash")
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(.redAccent)
                        .frame(width: 16, height: 16),
                    shouldExpand: false
                ) {
                    action()
                }
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

    @ViewBuilder
    private func footnoteSection(_ note: String) -> some View {
        BodySText(note, textColor: .white64)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Tags Section

    @ViewBuilder
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

    @ViewBuilder
    private var footerBar: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.customBlack.opacity(0), .customBlack],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)

            VStack(alignment: .leading, spacing: 0) {
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
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .background(Color.customBlack)
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
