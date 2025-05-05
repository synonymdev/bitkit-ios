import SwiftUI

struct SuggestionCardData: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let description: String
    let imageName: String
    let color: Color
    let action: SuggestionAction
}

enum SuggestionAction: Hashable {
    case fundingOptions
    case invite
    case quickpay
    case support
    case profile
    case none
}

let cards: [SuggestionCardData] = [
    SuggestionCardData(
        title: localizedString("cards__backupSeedPhrase__title"), description: localizedString("cards__backupSeedPhrase__description"),
        imageName: "safe", color: .blue24, action: .none),
    SuggestionCardData(
        title: localizedString("cards__lightning__title"), description: localizedString("cards__lightning__description"), imageName: "lightning",
        color: .purple24, action: .fundingOptions),
    SuggestionCardData(
        title: localizedString("cards__pin__title"), description: localizedString("cards__pin__description"), imageName: "shield", color: .green24,
        action: .none
    ),
    SuggestionCardData(
        title: localizedString("cards__buyBitcoin__title"), description: localizedString("cards__buyBitcoin__description"), imageName: "b-emboss",
        color: .brand24, action: .none),
    SuggestionCardData(
        title: localizedString("cards__support__title"), description: localizedString("cards__support__description"), imageName: "lightbulb",
        color: .yellow24, action: .support),
    SuggestionCardData(
        title: localizedString("cards__invite__title"), description: localizedString("cards__invite__description"), imageName: "group",
        color: .blue24, action: .invite),
    SuggestionCardData(
        title: localizedString("cards__quickpay__title"), description: localizedString("cards__quickpay__description"), imageName: "fast-forward",
        color: .green24, action: .quickpay),
    SuggestionCardData(
        title: localizedString("cards__slashtagsProfile__title"), description: localizedString("cards__slashtagsProfile__description"),
        imageName: "crown",
        color: .brand24, action: .profile),
]

struct Suggestions: View {
    @State private var path: [SuggestionAction] = []
    @State private var ignoringCardTaps = false
    @State private var lastActionTime: Date? = nil

    let cardSize: CGFloat = 152
    let cardSpacing: CGFloat = 16

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 0) {
                CaptionText(localizedString("cards__suggestions"))
                    .textCase(.uppercase)
                    .padding(.horizontal)
                    .padding(.bottom, 16)

                SnapCarousel(
                    items: cards,
                    itemSize: cardSize,
                    itemSpacing: cardSpacing,
                    onItemTap: { card in
                        // Only process taps if we're not ignoring them and there's no recent action
                        if !ignoringCardTaps && !hasRecentNavigationAction() {
                            switch card.action {
                            case .fundingOptions:
                                navigateToAction(.fundingOptions)
                            case .invite:
                                break
                            case .quickpay, .support:
                                navigateToAction(.support)
                            case .profile:
                                break
                            case .none:
                                break
                            }
                        }
                    }
                ) { card in
                    SuggestionCard(
                        data: card,
                        onDismiss: {
                            // Set flag to ignore card taps temporarily
                            ignoringCardTaps = true

                            // Just log the card being dismissed
                            print("Card dismissed: \(card.title) (ID: \(card.id))")

                            // Reset the flag after a delay
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                ignoringCardTaps = false
                            }
                        })
                }
                .frame(height: cardSize)
                .padding(.bottom, 16)
            }
            .navigationDestination(for: SuggestionAction.self) { action in
                switch action {
                case .fundingOptions:
                    FundingOptionsView()
                case .quickpay, .support:
                    SettingsListView()
                default:
                    EmptyView()
                }
            }
        }
    }

    // Helper to track navigation actions with debouncing
    private func navigateToAction(_ action: SuggestionAction) {
        // Track navigation time to prevent rapid duplicate navigations
        lastActionTime = Date()
        path.append(action)
    }

    // Check if there was a recent navigation action to prevent duplicates
    private func hasRecentNavigationAction() -> Bool {
        guard let lastTime = lastActionTime else { return false }
        // If the last action was less than 1 second ago, consider it recent
        return Date().timeIntervalSince(lastTime) < 1.0
    }
}

#Preview {
    VStack {
        Suggestions()
    }
    .preferredColorScheme(.dark)
}
