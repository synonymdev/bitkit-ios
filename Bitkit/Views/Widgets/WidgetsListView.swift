import SwiftUI

struct WidgetsListView: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var widgets: WidgetsViewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(WidgetType.allCases, id: \.rawValue) { widgetType in
                    WidgetListItem(id: widgetType)
                }
            }
            .padding(.top)
            .padding(.horizontal)
        }
        .navigationTitle(localizedString("widgets__add"))
        .navigationBarTitleDisplayMode(.inline)
        .backToWalletButton()
    }
}

#Preview {
    NavigationStack {
        WidgetsListView()
            .environmentObject(AppViewModel())
            .environmentObject(NavigationViewModel())
            .environmentObject(CurrencyViewModel())
            .environmentObject(WidgetsViewModel())
    }
    .preferredColorScheme(.dark)
}
