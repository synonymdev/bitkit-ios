import SwiftUI

struct WidgetsListView: View {
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var settings: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(title: t("widgets__add"))

            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(WidgetType.allCases, id: \.rawValue) { widgetType in
                                WidgetListItem(id: widgetType, isDisabled: !settings.showWidgets)
                            }
                        }

                        Spacer()

                        if !settings.showWidgets {
                            CustomButton(title: t("widgets__list__button")) {
                                navigation.navigate(.widgetsSettings)
                            }
                        }
                    }
                    .frame(minHeight: geometry.size.height)
                    .padding(.top, 16)
                    .bottomSafeAreaPadding()
                }
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
