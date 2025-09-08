import SwiftUI

struct WidgetsListView: View {
    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("widgets__add"))

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(WidgetType.allCases, id: \.rawValue) { widgetType in
                        WidgetListItem(id: widgetType)
                    }
                }
                .padding(.top)
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
    }
}

#Preview {
    NavigationStack {
        WidgetsListView()
    }
    .preferredColorScheme(.dark)
}
