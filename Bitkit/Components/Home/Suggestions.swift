import SwiftUI

struct SuggestionCardData: Identifiable, Hashable {
    let id: String
    let title: String
    let description: String
    let imageName: String
    let color: Color
    let action: SuggestionAction
}

enum SuggestionAction: Hashable {
    case backup
    case buyBitcoin
    case invite
    case profile
    case quickpay
    case secure
    case shop
    case support
    case transferToSpending
}

let cards: [SuggestionCardData] = [
    SuggestionCardData(
        id: "backupSeedPhrase",
        title: localizedString("cards__backupSeedPhrase__title"),
        description: localizedString("cards__backupSeedPhrase__description"),
        imageName: "safe",
        color: .blue24,
        action: .backup
    ),
    SuggestionCardData(
        id: "pin",
        title: localizedString("cards__pin__title"),
        description: localizedString("cards__pin__description"),
        imageName: "shield",
        color: .green24,
        action: .secure
    ),
    SuggestionCardData(
        id: "buyBitcoin",
        title: localizedString("cards__buyBitcoin__title"),
        description: localizedString("cards__buyBitcoin__description"),
        imageName: "b-emboss",
        color: .brand24,
        action: .buyBitcoin
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
        id: "invite",
        title: localizedString("cards__invite__title"),
        description: localizedString("cards__invite__description"),
        imageName: "group",
        color: .blue24,
        action: .invite
    ),
    SuggestionCardData(
        id: "quickpay",
        title: localizedString("cards__quickpay__title"),
        description: localizedString("cards__quickpay__description"),
        imageName: "fast-forward",
        color: .green24,
        action: .quickpay
    ),
    SuggestionCardData(
        id: "shop",
        title: localizedString("cards__shop__title"),
        description: localizedString("cards__shop__description"),
        imageName: "bag",
        color: .yellow24,
        action: .shop
    ),
    SuggestionCardData(
        id: "profile",
        title: localizedString("cards__slashtagsProfile__title"),
        description: localizedString("cards__slashtagsProfile__description"),
        imageName: "crown",
        color: .brand24,
        action: .profile
    ),
]

struct Suggestions: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var settings: SettingsViewModel

    @State private var showShareSheet = false
    // In-memory set of dismissed card keys
    @State private var dismissedCards: Set<String> = []
    // Prevent duplicate item taps when the card is dismissed
    @State private var ignoringCardTaps = false

    let cardSize: CGFloat = 152
    let cardSpacing: CGFloat = 16

    // Filter out cards that have already been completed or dismissed
    private var filteredCards: [SuggestionCardData] {
        cards.filter { card in
            // Filter out completed actions
            if card.action == .secure && settings.pinEnabled {
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
                        if !ignoringCardTaps {
                            onItemTap(card)
                        }
                    }
                ) { card in
                    SuggestionCard(
                        data: card,
                        onDismiss: { dismissCard(card) })
                }
                .id("suggestions-\(filteredCards.count)-\(dismissedCards.count)")
                .frame(height: cardSize)
                .padding(.bottom, 16)
            }
            .padding(.top, 32)
            .onAppear {
                loadDismissedCards()
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(activityItems: [
                    localizedString(
                        "settings__about__shareText",
                        variables: [
                            "appStoreUrl": Env.appStoreUrl,
                            "playStoreUrl": Env.playStoreUrl,
                        ])
                ])
            }
        }
    }

    private func onItemTap(_ card: SuggestionCardData) {
        var route: Route?

        switch card.action {
        case .backup:
            sheets.showSheet(.backup, data: BackupConfig())
        case .buyBitcoin:
            route = .buyBitcoin
        case .invite:
            showShareSheet = true
        case .profile:
            route = app.hasSeenProfileIntro ? .profile : .profileIntro
        case .quickpay:
            route = app.hasSeenQuickpayIntro ? .quickpay : .quickpayIntro
        case .secure:
            sheets.showSheet(.security, data: SecurityConfig(showLaterButton: true))
        case .shop:
            route = app.hasSeenShopIntro ? .shopDiscover : .shopIntro
        case .support:
            route = .support
        case .transferToSpending:
            route = app.hasSeenTransferToSpendingIntro ? .fundingOptions : .transferIntro
        }

        if let route = route {
            navigation.navigate(route)
        }
    }

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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            ignoringCardTaps = false
        }
    }
}

#Preview {
    VStack {
        Suggestions()
    }
    .environmentObject(SheetViewModel())
    .environmentObject(SettingsViewModel())
    .preferredColorScheme(.dark)
}
