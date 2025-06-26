import SwiftUI

// Category data structure
struct ShopCategory: Identifiable {
    let id = UUID()
    let title: String
    let route: String
    let iconName: String
}

// Shop discover cards data
struct ShopCard: Identifiable {
    let id = UUID()
    let title: String
    let description: String
    let imageName: String
    let color: Color
    let route: String
}

struct ShopDiscover: View {
    @EnvironmentObject var navigation: NavigationViewModel

    // Categories data
    private let categories: [ShopCategory] = [
        ShopCategory(title: "Apparel", route: "buy/apparel", iconName: "pedestrian"),
        ShopCategory(title: "Automobiles", route: "buy/automobiles", iconName: "car"),
        ShopCategory(title: "Cruises", route: "buy/cruises", iconName: "train"),
        ShopCategory(title: "Ecommerce", route: "buy/ecommerce", iconName: "shopping-cart"),
        ShopCategory(title: "Electronics", route: "buy/electronics", iconName: "printer"),
        ShopCategory(title: "Entertainment", route: "buy/entertainment", iconName: "headphones"),
        ShopCategory(title: "Experiences", route: "buy/experiences", iconName: "globe"),
        ShopCategory(title: "Flights", route: "buy/flights", iconName: "airplane"),
        ShopCategory(title: "Food", route: "buy/food", iconName: "storefront"),
        ShopCategory(title: "Food Delivery", route: "buy/food-delivery", iconName: "bicycle"),
        ShopCategory(title: "Games", route: "buy/games", iconName: "game-controller"),
        ShopCategory(title: "Gifts", route: "buy/gifts", iconName: "gift"),
        ShopCategory(title: "Groceries", route: "buy/groceries", iconName: "shopping-bag"),
        ShopCategory(title: "Health & Beauty", route: "buy/health-beauty", iconName: "heartbeat"),
        ShopCategory(title: "Home", route: "buy/home", iconName: "house"),
        ShopCategory(title: "Multi-Brand", route: "buy/multi-brand", iconName: "stack"),
        ShopCategory(title: "Pets", route: "buy/pets", iconName: "horse"),
        ShopCategory(title: "Restaurants", route: "buy/restaurants", iconName: "fork-knife"),
        ShopCategory(title: "Retail", route: "buy/retail", iconName: "storefront"),
        ShopCategory(title: "Streaming", route: "buy/streaming", iconName: "video-camera"),
        ShopCategory(title: "Travel", route: "buy/travel", iconName: "airplane"),
        ShopCategory(title: "VoIP", route: "buy/voip", iconName: "phone-call"),
    ]

    // Featured cards data
    private let cards: [ShopCard] = [
        ShopCard(
            title: localizedString("other__shop__discover__gift-cards__title"),
            description: localizedString("other__shop__discover__gift-cards__description"),
            imageName: "gift-figure",
            color: .green24,
            route: "gift-cards"
        ),
        ShopCard(
            title: localizedString("other__shop__discover__esims__title"),
            description: localizedString("other__shop__discover__esims__description"),
            imageName: "globe-sphere",
            color: .yellow24,
            route: "esims"
        ),
        ShopCard(
            title: localizedString("other__shop__discover__refill__title"),
            description: localizedString("other__shop__discover__refill__description"),
            imageName: "phone",
            color: .purple24,
            route: "refill"
        ),
        ShopCard(
            title: localizedString("other__shop__discover__travel__title"),
            description: localizedString("other__shop__discover__travel__description"),
            imageName: "rocket2",
            color: .red24,
            route: "buy/travel"
        ),
    ]

    var body: some View {
        GeometryReader { geometry in
            let cardSize = (geometry.size.width - 32 - 16) / 2

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 16),
                            GridItem(.flexible(), spacing: 16),
                        ],
                        spacing: 16
                    ) {
                        ForEach(cards) { card in
                            ShopDiscoverCard(
                                title: card.title,
                                description: card.description,
                                imageName: card.imageName,
                                color: card.color,
                                size: cardSize
                            ) {
                                navigation.navigate(.shopMain(page: card.route))
                            }
                        }
                    }
                    .padding(.bottom, 16)

                    VStack {
                        CaptionText(localizedString("other__shop__discover__label"))
                            .textCase(.uppercase)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 50)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)

                    LazyVStack(spacing: 0) {
                        ForEach(categories) { category in
                            ShopCategoryRow(
                                title: category.title,
                                iconName: category.iconName
                            ) {
                                navigation.navigate(.shopMain(page: category.route))
                            }
                        }
                    }
                }
                .padding(.top, 16)
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle(localizedString("other__shop__discover__nav_title"))
        .navigationBarTitleDisplayMode(.inline)
        .backToWalletButton()
    }
}

// MARK: - Shop Discover Card Component
struct ShopDiscoverCard: View {
    let title: String
    let description: String
    let imageName: String
    let color: Color
    let size: CGFloat
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                Image(imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .frame(maxWidth: .infinity, alignment: .center)

                Text(title)
                    .font(.custom(Fonts.black, size: 20))
                    .lineLimit(1)
                    .kerning(-0.5)
                    .textCase(.uppercase)
                    .padding(.top, 4)

                CaptionBText(description)
            }
            .padding()
            .frame(width: size, height: size, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: color, location: 0.0),
                                .init(color: Color.black.opacity(0.1), location: 0.9),
                                .init(color: Color.black, location: 1.0),
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Shop Category Row Component
struct ShopCategoryRow: View {
    let title: String
    let iconName: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    CircularIcon(icon: iconName, size: 32)
                        .padding(.trailing, 8)

                    BodyMText(title, textColor: .textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image("chevron")
                        .resizable()
                        .foregroundColor(.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())

                Divider()
                    .padding(.vertical, 9)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    NavigationStack {
        ShopDiscover()
            .environmentObject(NavigationViewModel())
    }
    .preferredColorScheme(.dark)
}
