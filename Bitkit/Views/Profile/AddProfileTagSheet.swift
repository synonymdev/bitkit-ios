import SwiftUI

struct AddProfileTagSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (String) -> Void

    @State private var tag: String = ""
    @State private var showSuggestionsSheet = false

    private var canSave: Bool {
        !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("profile__add_tag_title"))

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    CaptionMText(t("profile__add_tag_label"), textColor: .white64)

                    tagFieldWithSuggestions
                }

                CustomButton(title: t("common__save")) {
                    onSave(tag.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .disabled(!canSave)
                .accessibilityIdentifier("AddTagSave")
            }
            .padding(.horizontal, 16)

            Spacer()
        }
        .sheetBackground()
        .presentationDetents([.height(300)])
        .presentationCornerRadius(32)
        .presentationDragIndicator(.hidden)
        .sheet(isPresented: $showSuggestionsSheet) {
            TagSuggestionsSheet { suggestion in
                tag = suggestion
            }
        }
    }

    @ViewBuilder
    private var tagFieldWithSuggestions: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                if tag.isEmpty {
                    Text(t("profile__add_tag_placeholder"))
                        .foregroundColor(.secondary)
                        .font(.custom(Fonts.semiBold, size: 15))
                }

                SwiftUI.TextField("", text: $tag)
                    .accentColor(.brandAccent)
                    .font(.custom(Fonts.semiBold, size: 15))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("AddTagInput")
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
            .accessibilityIdentifier("AddTagSuggestions")
        }
        .padding()
        .background(Color.white08)
        .cornerRadius(8)
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            AddProfileTagSheet { _ in }
        }
        .preferredColorScheme(.dark)
}
