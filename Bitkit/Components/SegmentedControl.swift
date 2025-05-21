import SwiftUI

struct SegmentedControl<T: Hashable & CaseIterable & CustomStringConvertible>: View {
    @Binding var selectedTab: T
    private let tabs: [T]
    @Namespace private var underlineNamespace

    init(selectedTab: Binding<T>) {
        self._selectedTab = selectedTab
        self.tabs = Array(T.allCases)
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(tabs, id: \.self) { tab in
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        selectedTab = tab
                    }
                }) {
                    VStack(spacing: 8) {
                        CaptionBText(tab.description, textColor: selectedTab == tab ? .white : .secondary)
                            .frame(maxWidth: .infinity)
                        ZStack {
                            Rectangle()
                                .frame(height: 2)
                                .foregroundColor(Color.white64)
                            if selectedTab == tab {
                                Rectangle()
                                    .frame(height: 2)
                                    .foregroundColor(Color.brandAccent)
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
        .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
    }
}
