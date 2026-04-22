import SwiftUI

struct AddLinkSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (String, String) -> Void

    @State private var label: String = ""
    @State private var url: String = ""
    @State private var showSuggestionsSheet = false

    private var canSave: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("profile__add_link_title"))

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    CaptionMText(t("profile__add_link_label"), textColor: .white64)

                    labelFieldWithSuggestions
                }

                VStack(alignment: .leading, spacing: 8) {
                    CaptionMText(t("profile__add_link_url"), textColor: .white64)

                    TextField(
                        t("profile__add_link_url_placeholder"),
                        text: $url,
                        backgroundColor: .white08,
                        testIdentifier: "AddLinkUrl"
                    )
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }

                CaptionText(t("profile__add_link_note"), textColor: .white50)

                CustomButton(title: t("common__save")) {
                    onSave(
                        label.trimmingCharacters(in: .whitespacesAndNewlines),
                        url.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    dismiss()
                }
                .disabled(!canSave)
                .accessibilityIdentifier("AddLinkSave")
            }
            .padding(.horizontal, 16)

            Spacer()
        }
        .sheetBackground()
        .presentationDetents([.height(460)])
        .presentationCornerRadius(32)
        .presentationDragIndicator(.hidden)
        .sheet(isPresented: $showSuggestionsSheet) {
            LinkSuggestionsSheet { suggestion in
                label = suggestion
            }
        }
    }

    @ViewBuilder
    private var labelFieldWithSuggestions: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                if label.isEmpty {
                    Text(t("profile__add_link_label_placeholder"))
                        .foregroundColor(.secondary)
                        .font(.custom(Fonts.semiBold, size: 15))
                }

                SwiftUI.TextField("", text: $label)
                    .accentColor(.brandAccent)
                    .font(.custom(Fonts.semiBold, size: 15))
                    .accessibilityIdentifier("AddLinkLabel")
            }

            Button {
                showSuggestionsSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image("lightbulb")
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)

                    Text(t("slashtags__profile_link_suggestions"))
                        .font(Fonts.semiBold(size: 13))
                        .foregroundColor(.pubkyGreen)
                }
                .padding(.horizontal, 8)
            }
            .accessibilityLabel(t("slashtags__profile_link_suggestions"))
            .accessibilityIdentifier("AddLinkSuggestions")
        }
        .padding()
        .background(Color.white08)
        .cornerRadius(8)
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            AddLinkSheet { _, _ in }
        }
        .preferredColorScheme(.dark)
}
