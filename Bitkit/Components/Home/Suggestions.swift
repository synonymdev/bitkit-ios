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
    case notifications
    case secure
    case shop
    case support
    case transferToSpending
}

let cards: [SuggestionCardData] = [
    SuggestionCardData(
        id: "backupSeedPhrase",
        title: t("cards__backupSeedPhrase__title"),
        description: t("cards__backupSeedPhrase__description"),
        imageName: "safe",
        color: .blue24,
        action: .backup
    ),
    SuggestionCardData(
        id: "transferToSpending",
        title: t("cards__lightning__title"),
        description: t("cards__lightning__description"),
        imageName: "lightning",
        color: .purple24,
        action: .transferToSpending
    ),
    SuggestionCardData(
        id: "pin",
        title: t("cards__pin__title"),
        description: t("cards__pin__description"),
        imageName: "shield-figure",
        color: .green24,
        action: .secure
    ),
    SuggestionCardData(
        id: "buyBitcoin",
        title: t("cards__buyBitcoin__title"),
        description: t("cards__buyBitcoin__description"),
        imageName: "b-emboss",
        color: .brand24,
        action: .buyBitcoin
    ),
    SuggestionCardData(
        id: "support",
        title: t("cards__support__title"),
        description: t("cards__support__description"),
        imageName: "lightbulb",
        color: .yellow24,
        action: .support
    ),
    SuggestionCardData(
        id: "invite",
        title: t("cards__invite__title"),
        description: t("cards__invite__description"),
        imageName: "group",
        color: .blue24,
        action: .invite
    ),
    SuggestionCardData(
        id: "quickpay",
        title: t("cards__quickpay__title"),
        description: t("cards__quickpay__description"),
        imageName: "fast-forward",
        color: .green24,
        action: .quickpay
    ),
    SuggestionCardData(
        id: "notifications",
        title: t("cards__notifications__title"),
        description: t("cards__notifications__description_alt"),
        imageName: "bell-card-figure",
        color: .purple24,
        action: .notifications
    ),
    SuggestionCardData(
        id: "shop",
        title: t("cards__shop__title"),
        description: t("cards__shop__description"),
        imageName: "bag",
        color: .yellow24,
        action: .shop
    ),
    SuggestionCardData(
        id: "profile",
        title: t("cards__slashtagsProfile__title"),
        description: t("cards__slashtagsProfile__description"),
        imageName: "crown",
        color: .brand24,
        action: .profile
    ),
]

extension SuggestionCardData {
    var accessibilityId: String {
        switch action {
        case .backup:
            return "back_up"
        case .buyBitcoin:
            return "buy"
        case .invite:
            return "invite"
        case .profile:
            return "profile"
        case .quickpay:
            return "quick_pay"
        case .notifications:
            return "notifications"
        case .secure:
            return "secure"
        case .shop:
            return "shop"
        case .support:
            return "support"
        case .transferToSpending:
            return "lightning"
        }
    }
}

struct Suggestions: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var suggestionsManager: SuggestionsManager

    @State private var showShareSheet = false
    // Prevent duplicate item taps when the card is dismissed
    @State private var ignoringCardTaps = false

    let cardSize: CGFloat = 152
    let cardSpacing: CGFloat = 16

    // Filter out cards that have already been completed or dismissed
    private var filteredCards: [SuggestionCardData] {
        cards.filter { card in
            // Filter out completed actions
            if card.action == .backup && app.backupVerified {
                return false
            }

            if card.action == .secure && settings.pinEnabled {
                return false
            }

            if card.action == .notifications && settings.enableNotifications {
                return false
            }

            // Filter out dismissed cards
            if suggestionsManager.isDismissed(card.id) {
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
                CaptionMText(t("cards__suggestions"))
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
                        onDismiss: { dismissCard(card) }
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("Suggestion-\(card.accessibilityId)")
                }
                .accessibilityIdentifier("Suggestions")
                .id("suggestions-\(filteredCards.count)-\(suggestionsManager.dismissedIds.count)")
                .frame(height: cardSize)
                .padding(.bottom, 16)
            }
            .padding(.top, 32)
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(activityItems: [
                    t(
                        "settings__about__shareText",
                        variables: [
                            "appStoreUrl": Env.appStoreUrl,
                            "playStoreUrl": Env.playStoreUrl,
                        ]
                    ),
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
        case .notifications:
            route = app.hasSeenNotificationsIntro ? .notifications : .notificationsIntro
        case .secure:
            sheets.showSheet(.security, data: SecurityConfig(showLaterButton: true))
        case .shop:
            route = app.hasSeenShopIntro ? .shopDiscover : .shopIntro
        case .support:
            route = .support
        case .transferToSpending:
            route = app.hasSeenTransferIntro ? .fundingOptions : .transferIntro
        }

        if let route {
            navigation.navigate(route)
        }
    }

    private func dismissCard(_ card: SuggestionCardData) {
        ignoringCardTaps = true

        // Force UI update by using withAnimation
        withAnimation(.easeInOut(duration: 0.3)) {
            suggestionsManager.dismiss(card.id)
        }

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
    .environmentObject(SettingsViewModel.shared)
    .preferredColorScheme(.dark)
}
