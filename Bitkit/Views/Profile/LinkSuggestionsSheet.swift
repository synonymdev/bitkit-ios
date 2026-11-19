import SwiftUI

struct LinkSuggestionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var webLinksOnly = false
    let onSelect: (String) -> Void

    /// Suggestions whose links are not web links, which social v1 profiles reject.
    private static let nonWebSuggestions: Set = ["Email", "Phone"]

    private var suggestions: [String] {
        webLinksOnly ? Self.allSuggestions.filter { !Self.nonWebSuggestions.contains($0) } : Self.allSuggestions
    }

    private static let allSuggestions = [
        "Email", "Phone", "Website", "Twitter",
        "Telegram", "Instagram", "Facebook",
        "LinkedIn", "Github", "Calendly",
        "Vimeo", "YouTube", "Twitch",
        "Pinterest", "TikTok", "Spotify",
    ]

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("profile__suggestions_title"), showBackButton: true)
                .padding(.horizontal, 16)

            WrappingHStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    IconActionButton(title: suggestion, accessibilityId: "Tag-\(suggestion)") {
                        onSelect(suggestion)
                        dismiss()
                    }
                }
            }
            .padding(.horizontal, 16)

            Spacer()
        }
        .sheetBackground()
        .presentationDetents([.height(460)])
        .presentationCornerRadius(32)
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            LinkSuggestionsSheet { _ in }
        }
        .preferredColorScheme(.dark)
}
