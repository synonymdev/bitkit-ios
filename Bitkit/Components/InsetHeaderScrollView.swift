import SwiftUI

// MARK: - InsetHeaderScrollView

// Measured top header (`safeAreaInset`) and scroll content with `minHeight` to fill the viewport below it.
// Optional `scrollModifier` for refresh, margins, etc.

private enum HeaderHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        guard next > 0 else { return }
        value = next
    }
}

private struct HeaderHeightMeasure: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: HeaderHeightPreferenceKey.self, value: proxy.size.height)
        }
    }
}

struct InsetHeaderScrollView<Header: View, Content: View, ScrollModifier: ViewModifier>: View {
    let header: () -> Header
    let content: () -> Content
    let scrollModifier: ScrollModifier

    @State private var headerHeight: CGFloat = 0

    init(
        header: @escaping () -> Header,
        content: @escaping () -> Content,
        scrollModifier: ScrollModifier = EmptyModifier()
    ) {
        self.header = header
        self.content = content
        self.scrollModifier = scrollModifier
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView(showsIndicators: false) {
                content()
                    .frame(minHeight: contentMinHeight(in: geo), alignment: .top)
            }
            .modifier(scrollModifier)
            .safeAreaInset(edge: .top, spacing: 0) {
                header().background(HeaderHeightMeasure())
            }
            .onPreferenceChange(HeaderHeightPreferenceKey.self) { newValue in
                if newValue > 0 { headerHeight = newValue }
            }
        }
    }

    /// Before the first header measurement, use full height so `minHeight` is non-negative.
    private func contentMinHeight(in geo: GeometryProxy) -> CGFloat {
        let insetTop = headerHeight > 0 ? headerHeight : 0
        return max(0, geo.size.height - insetTop)
    }
}
