import SwiftUI

struct SuggestionCardData: Identifiable, Hashable {
    let id: String
    let title: String
    let description: String
    let imageName: String
    let color: Color
    let action: SuggestionAction

    init(id: String, title: String, description: String, imageName: String, color: Color, action: SuggestionAction) {
        self.id = id
        self.title = title
        self.description = description
        self.imageName = imageName
        self.color = color
        self.action = action
    }
}

enum SuggestionAction: Hashable {
    case buyBitcoin
    case invite
    case profile
    case setupPin
    case quickpay
    case shop
    case support
    case transferToSpending
    case none
}

let cards: [SuggestionCardData] = [
    SuggestionCardData(
        id: "backupSeedPhrase",
        title: localizedString("cards__backupSeedPhrase__title"),
        description: localizedString("cards__backupSeedPhrase__description"),
        imageName: "safe",
        color: .blue24,
        action: .none
    ),
    SuggestionCardData(
        title: localizedString("cards__buyBitcoin__title"), description: localizedString("cards__buyBitcoin__description"), imageName: "b-emboss",
        color: .brand24, action: .buyBitcoin),
    SuggestionCardData(
        id: "pin",
        title: localizedString("cards__pin__title"),
        description: localizedString("cards__pin__description"),
        imageName: "shield",
        color: .green24,
        action: .setupPin
    ),
    SuggestionCardData(
        id: "buyBitcoin",
        title: localizedString("cards__buyBitcoin__title"),
        description: localizedString("cards__buyBitcoin__description"),
        imageName: "b-emboss",
        color: .brand24,
        action: .none
    ),
    SuggestionCardData(
        id: "support",
        title: localizedString("cards__support__title"),
        description: localizedString("cards__support__description"),
        imageName: "lightbulb",
        color: .yellow24,
        action: .support
    ),
    SuggestionCardData(
        title: localizedString("cards__shop__title"), description: localizedString("cards__shop__description"), imageName: "bag",
        color: .yellow24, action: .shop),
    SuggestionCardData(
        title: localizedString("cards__slashtagsProfile__title"), description: localizedString("cards__slashtagsProfile__description"),
        imageName: "crown",
        color: .brand24,
        action: .profile
    ),
]

struct Suggestions: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @State private var ignoringCardTaps = false
    @State private var lastActionTime: Date? = nil

    // In-memory set of dismissed card keys
    @State private var dismissedCards: Set<String> = []

    let cardSize: CGFloat = 152
    let cardSpacing: CGFloat = 16

    // Filter out cards that have already been completed or dismissed
    private var filteredCards: [SuggestionCardData] {
        cards.filter { card in
            // Filter out completed actions
            if card.action == .setupPin && settings.pinEnabled {
                return false
            }

            // Filter out dismissed cards
            if dismissedCards.contains(card.id) {
                return false
            }

            return true
        }
    }

    var body: some View {
        if filteredCards.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                CaptionText(localizedString("cards__suggestions"))
                    .textCase(.uppercase)
                    .padding(.horizontal)
                    .padding(.bottom, 16)

                SnapCarousel(
                    items: filteredCards,
                    itemSize: cardSize,
                    itemSpacing: cardSpacing,
                    onItemTap: { card in
                        if !ignoringCardTaps && !hasRecentNavigationAction() {
                            switch card.action {
                            case .transferToSpending:
                                navigateToAction(.transferToSpending)
                            case .invite:
                                break
                            case .quickpay, .support:
                                navigateToAction(.support)
                            case .profile:
                                break
                            case .setupPin:
                                app.showSetupSecuritySheet = true
                                case .quickpay:
                            navigateToAction(.quickpay)
                            case .support:
                                navigateToAction(.support)
                            case .profile:
                                navigateToAction(.profile)
                            case .shop:
                                navigateToAction(.shop)        
                            case .none:
                                break
                            }
                        }
                    }
                ) { card in
                    SuggestionCard(
                        data: card,
                        onDismiss: {
                            dismissCard(card)
                        })
                }
                .id("suggestions-\(filteredCards.count)-\(dismissedCards.count)")
                .frame(height: cardSize)
                .padding(.bottom, 16)
            }
            .padding(.top, 32)
            .onAppear {
                loadDismissedCards()
            }
        }
    }

    // MARK: - Dismissed Cards Management

    private func loadDismissedCards() {
        let dismissedArray = UserDefaults.standard.stringArray(forKey: "dismissedSuggestionCards") ?? []
        dismissedCards = Set(dismissedArray)
    }

    private func saveDismissedCards() {
        let dismissedArray = Array(dismissedCards)
        UserDefaults.standard.set(dismissedArray, forKey: "dismissedSuggestionCards")
    }

    private func dismissCard(_ card: SuggestionCardData) {
        ignoringCardTaps = true

        // Force UI update by using withAnimation
        withAnimation(.easeInOut(duration: 0.3)) {
            dismissedCards.insert(card.id)
        }

        saveDismissedCards()

        Logger.debug("Card dismissed: \(card.title) (ID: \(card.id))", context: "Suggestions")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            ignoringCardTaps = false
        }
    }

    // Helper to track navigation actions with debouncing
    private func navigateToAction(_ action: SuggestionAction) {
        // Track navigation time to prevent rapid duplicate navigations
        lastActionTime = Date()

        let screenToNavigate: Route?
        switch action {
        case .transferToSpending:
            if app.hasSeenTransferToSpendingIntro {
                screenToNavigate = .fundingOptions
            } else {
                screenToNavigate = .transferIntro
            }
        case .buyBitcoin:
            screenToNavigate = .buyBitcoin
        case .quickpay:
            screenToNavigate = app.hasSeenQuickpayIntro ? .settings : .quickpayIntro
        case .support:
            screenToNavigate = .settings
        case .profile:
            screenToNavigate = app.hasSeenProfileIntro ? .profile : .profileIntro
        case .shop:
            screenToNavigate = app.hasSeenShopIntro ? .shopDiscover : .shopIntro
        case .invite, .none:
            screenToNavigate = nil // These actions might not navigate, or could trigger sheets/other UI
            // Handle non-navigation actions here if needed, e.g.:
            // if action == .invite { self.showInviteSheet = true }
            print("SuggestionAction \(action) does not map to a main AppScreen or is not yet handled for navigation.")
        }

        if let screen = screenToNavigate {
            navigation.navigate(screen)
        }
    }

    // TODO: Why is this needed?
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
    .environmentObject(SettingsViewModel())
    .preferredColorScheme(.dark)
}
