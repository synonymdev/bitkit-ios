import SwiftUI

struct TabItem<T: Hashable & CustomStringConvertible> {
    let tab: T
    let activeColor: Color?
    let badge: Int?
    let accessibilityIdentifier: String?

    init(_ tab: T, activeColor: Color? = nil, badge: Int? = nil, accessibilityIdentifier: String? = nil) {
        self.tab = tab
        self.activeColor = activeColor
        self.badge = badge
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}

struct SegmentedControl<T: Hashable & CustomStringConvertible>: View {
    @Binding var selectedTab: T
    private let tabItems: [TabItem<T>]
    private let defaultActiveColor: Color
    private let inactiveColor: Color?
    @Namespace private var underlineNamespace

    init(selectedTab: Binding<T>, tabs: [T], activeColor: Color = .textPrimary, inactiveColor: Color? = nil) {
        _selectedTab = selectedTab
        tabItems = tabs.map { TabItem($0) }
        defaultActiveColor = activeColor
        self.inactiveColor = inactiveColor
    }

    init(selectedTab: Binding<T>, tabItems: [TabItem<T>], defaultActiveColor: Color = .textPrimary, inactiveColor: Color? = nil) {
        _selectedTab = selectedTab
        self.tabItems = tabItems
        self.defaultActiveColor = defaultActiveColor
        self.inactiveColor = inactiveColor
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(tabItems, id: \.tab) { tabItem in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTab = tabItem.tab
                    }
                }) {
                    VStack(spacing: 8) {
                        // A hidden copy of the badge balances the visible one, so the label stays
                        // centred in its tab with the badge just after it. Every tab reserves the
                        // badge height so the underlines stay level.
                        HStack(spacing: 8) {
                            badge(for: tabItem)
                                .hidden()
                            CaptionBText(
                                tabItem.tab.description,
                                textColor: selectedTab == tabItem.tab ? .white : inactiveColor ?? .secondary
                            )
                            badge(for: tabItem)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 20)
                        ZStack {
                            Rectangle()
                                .frame(height: 2)
                                .foregroundColor(inactiveColor ?? .white64)

                            if selectedTab == tabItem.tab {
                                Rectangle()
                                    .frame(height: 2)
                                    .foregroundColor(tabItem.activeColor ?? defaultActiveColor)
                                    .matchedGeometryEffect(id: "underline", in: underlineNamespace)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityIdentifier(tabItem.accessibilityIdentifier ?? "Tab-\(tabItem.tab.description.lowercased())")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
    }

    @ViewBuilder
    private func badge(for tabItem: TabItem<T>) -> some View {
        if let badge = tabItem.badge, badge > 0 {
            CaptionBText("\(badge)", textColor: .white)
                .frame(minWidth: 20, minHeight: 20)
                .background(Color.brandAccent)
                .clipShape(Circle())
                .accessibilityLabel(t("wallet__payment_requests_count", variables: ["count": "\(badge)"]))
        }
    }
}
