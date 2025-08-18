import SwiftUI

struct SeedInputAccessory: View {
    let currentWord: String
    let onWordSelected: (String) -> Void

    private var suggestions: [String] {
        let trimmed = currentWord.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return Array(BIP39.wordlist.sorted().prefix(5))
        }
        return BIP39.getSuggestions(for: trimmed, limit: 5)
    }

    var body: some View {
        VStack(spacing: 0) {
            CaptionText(t("onboarding__restore_suggestions"))
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        CustomButton(title: suggestion, size: .small) {
                            onWordSelected(suggestion)
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 12)
            }
        }
        .background(Color(UIColor.systemBackground))
    }
}
