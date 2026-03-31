import SwiftUI

struct LinkSuggestionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onSelect: (String) -> Void

    private let suggestions = [
        "Email", "Phone", "Website", "Twitter",
        "Telegram", "Instagram", "Facebook",
        "LinkedIn", "Github", "Calendly",
        "Vimeo", "YouTube", "Twitch",
        "Pinterest", "TikTok", "Spotify",
    ]

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("profile__suggestions_title"), showBackButton: true)

            WrappingHStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Tag(suggestion, onPress: {
                        onSelect(suggestion)
                        dismiss()
                    })
                }
            }
            .padding(.horizontal, 16)

            Spacer()
        }
        .sheetBackground()
        .presentationDetents([.height(400)])
        .presentationCornerRadius(32)
        .presentationDragIndicator(.hidden)
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            LinkSuggestionsSheet { _ in }
        }
        .preferredColorScheme(.dark)
}
