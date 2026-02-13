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

    @State private var showShareSheet = false

    private var walletSuggestionState: WalletSuggestionState {
        if wallet.totalBalanceSats == 0 {
            return .empty
        }
        if wallet.totalLightningSats > 0 {
            return .spending
        }
        return .onchain
    }

    /// Up to 4 cards for the current wallet state, in priority order; completed and dismissed cards are skipped and the next in the set is shown. In
    /// preview, exactly 2 fixed cards.
    private var filteredCards: [SuggestionCardData] {
        if isPreview {
            return Array(cards.prefix(2))
        }
        let orderedIds = suggestionOrderByState[walletSuggestionState] ?? []
        var result: [SuggestionCardData] = []
        for id in orderedIds {
            guard let card = cardsById[id] else { continue }
            if isCardCompleted(card) { continue }
            if suggestionsManager.isDismissed(card.id) { continue }
            result.append(card)
            if result.count >= 4 { break }
        }
        return result
    }

    private func isCardCompleted(_ card: SuggestionCardData) -> Bool {
        switch card.action {
        case .backup:
            return app.backupVerified
        case .notifications:
            return settings.enableNotifications
        case .quickpay:
            return settings.enableQuickpay
        case .secure:
            return settings.pinEnabled
        default:
            return false
        }
    }

    var body: some View {
        if filteredCards.isEmpty {
            EmptyView()
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                ],
                spacing: 16
            ) {
                ForEach(filteredCards) { card in
                    SuggestionCard(data: card, onDismiss: { dismissCard(card) })
                        .onTapGesture { if !isPreview { onItemTap(card) } }
                        .accessibilityIdentifier("Suggestion-\(card.accessibilityId)")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("Suggestions")
            }
            .allowsHitTesting(!isPreview)
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
