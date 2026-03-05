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
    // case hardware
    case invite
    case notifications
    case profile
    case quickpay
    case secure
    case shop
    case support
    case transferToSpending
}

/// Wallet state used to choose which suggestion cards to show and in what order.
enum WalletSuggestionState {
    case empty
    case onchain
    case spending
}

/// Ordered suggestion card IDs per wallet state (priority: first = highest).
/// Max 4 cards are shown; when one is dismissed or completed, the next in this list is shown.
private let suggestionOrderByState: [WalletSuggestionState: [String]] = [
    .empty: ["buyBitcoin", "transferToSpending", "support", "backupSeedPhrase", "pin", "profile", "invite"],
    .onchain: ["backupSeedPhrase", "pin", "transferToSpending", "support", "profile", "invite", "buyBitcoin"],
    .spending: ["quickpay", "notifications", "shop", "profile", "support", "invite", "buyBitcoin"],
]

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
    // SuggestionCardData(
    //     id: "hardware",
    //     title: t("cards__hardware__title"),
    //     description: t("cards__hardware__description"),
    //     imageName: "trezor-card",
    //     color: .blue24,
    //     action: .hardware
    // ),
]

private let cardsById: [String: SuggestionCardData] = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })

extension SuggestionCardData {
    var accessibilityId: String {
        switch action {
        case .backup:
            return "back_up"
        case .buyBitcoin:
            return "buy"
        // case .hardware:
        //     return "hardware"
        case .invite:
            return "invite"
        case .notifications:
            return "notifications"
        case .profile:
            return "profile"
        case .quickpay:
            return "quick_pay"
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
    /// When true, show only two static cards and ignore taps (e.g. widget detail preview).
    var isPreview: Bool = false

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var sheets: SheetViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var suggestionsManager: SuggestionsManager
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var pubkyProfile: PubkyProfileManager

    @State private var showShareSheet = false

    /// Which suggestion cards to show.
    /// Up to 4 for current wallet state, in priority order; completed and dismissed are skipped.
    /// In widget preview: 2 fixed cards.
    static func visibleCards(
        wallet: WalletViewModel,
        app: AppViewModel,
        settings: SettingsViewModel,
        suggestionsManager: SuggestionsManager,
        pubkyProfile: PubkyProfileManager? = nil,
        isPreview: Bool = false
    ) -> [SuggestionCardData] {
        if isPreview {
            return Array(cards.prefix(2))
        }
        let state: WalletSuggestionState = if wallet.totalBalanceSats == 0 {
            .empty
        } else if wallet.totalLightningSats > 0 {
            .spending
        } else {
            .onchain
        }
        let orderedIds = suggestionOrderByState[state] ?? []
        var result: [SuggestionCardData] = []
        for id in orderedIds {
            guard let card = cardsById[id] else { continue }
            if isCardCompleted(card, app: app, settings: settings, pubkyProfile: pubkyProfile) { continue }
            if suggestionsManager.isDismissed(card.id) { continue }
            result.append(card)
            if result.count >= 4 { break }
        }
        return result
    }

    /// Whether the user has completed this suggestion (e.g. backup verified, pin enabled, notifications on).
    private static func isCardCompleted(_ card: SuggestionCardData, app: AppViewModel, settings: SettingsViewModel,
                                        pubkyProfile: PubkyProfileManager? = nil) -> Bool
    {
        switch card.action {
        case .backup: return app.backupVerified
        case .notifications: return settings.enableNotifications
        case .profile: return pubkyProfile?.isAuthenticated ?? false
        case .quickpay: return settings.enableQuickpay
        case .secure: return settings.pinEnabled
        default: return false
        }
    }

    /// Cards to display in this view; delegates to the static visibleCards (same logic as the widget list filter).
    private var visibleCards: [SuggestionCardData] {
        Self.visibleCards(wallet: wallet, app: app, settings: settings, suggestionsManager: suggestionsManager, pubkyProfile: pubkyProfile, isPreview: isPreview)
    }

    var body: some View {
        if visibleCards.isEmpty {
            EmptyView()
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                ],
                spacing: 16
            ) {
                ForEach(visibleCards) { card in
                    SuggestionCard(data: card, onDismiss: { dismissCard(card) })
                        .onTapGesture { if !isPreview { onItemTap(card) } }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("Suggestion-\(card.accessibilityId)")
                }
            }
            .allowsHitTesting(!isPreview)
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
            if pubkyProfile.isAuthenticated {
                route = .profile
            } else if app.hasSeenProfileIntro {
                route = .pubkyRingAuth
            } else {
                route = .profileIntro
            }
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
        // case .hardware:
        //     route = .support
        case .transferToSpending:
            route = app.hasSeenTransferIntro ? .fundingOptions : .transferIntro
        }

        if let route {
            navigation.navigate(route)
        }
    }

    private func dismissCard(_ card: SuggestionCardData) {
        withAnimation(.easeInOut(duration: 0.3)) {
            suggestionsManager.dismiss(card.id)
        }
    }
}

#Preview {
    VStack {
        Suggestions()
    }
    .environmentObject(AppViewModel())
    .environmentObject(NavigationViewModel())
    .environmentObject(SheetViewModel())
    .environmentObject(SettingsViewModel.shared)
    .environmentObject(SuggestionsManager())
    .environmentObject(WalletViewModel())
    .environmentObject(PubkyProfileManager())
    .preferredColorScheme(.dark)
}
