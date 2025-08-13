import SwiftUI

struct TabItem<T: Hashable & CustomStringConvertible> {
    let tab: T
    let activeColor: Color?

    init(_ tab: T, activeColor: Color? = nil) {
        self.tab = tab
        self.activeColor = activeColor
    }
}

struct SegmentedControl<T: Hashable & CustomStringConvertible>: View {
    @Binding var selectedTab: T
    private let tabItems: [TabItem<T>]
    private let defaultActiveColor: Color
    @Namespace private var underlineNamespace

    init(selectedTab: Binding<T>, tabs: [T], activeColor: Color = .brandAccent) {
        self._selectedTab = selectedTab
        self.tabItems = tabs.map { TabItem($0) }
        self.defaultActiveColor = activeColor
    }

    init(selectedTab: Binding<T>, tabItems: [TabItem<T>], defaultActiveColor: Color = .brandAccent) {
        self._selectedTab = selectedTab
        self.tabItems = tabItems
        self.defaultActiveColor = defaultActiveColor
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(tabItems, id: \.tab) { tabItem in
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        selectedTab = tabItem.tab
                    }
                }) {
                    VStack(spacing: 8) {
                        CaptionBText(tabItem.tab.description, textColor: selectedTab == tabItem.tab ? .white : .secondary)
                            .frame(maxWidth: .infinity)
                        ZStack {
                            Rectangle()
                                .frame(height: 2)
                                .foregroundColor(Color.white64)
                            if selectedTab == tabItem.tab {
                                Rectangle()
                                    .frame(height: 2)
                                    .foregroundColor(tabItem.activeColor ?? defaultActiveColor)
                                    .matchedGeometryEffect(id: "underline", in: underlineNamespace)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
    }
}
