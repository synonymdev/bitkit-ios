import SwiftUI

enum SettingsTab: String, CaseIterable, CustomStringConvertible {
    case general
    case security
    case advanced

    var description: String {
        switch self {
        case .general: return t("settings__general_title")
        case .security: return t("settings__security_title")
        case .advanced: return t("settings__advanced_title")
        }
    }
}

struct MainSettingsScreen: View {
    @State private var selectedTab: SettingsTab = .general

    private var settingsTabItems: [TabItem<SettingsTab>] {
        SettingsTab.allCases.map { TabItem($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__settings"))
                .padding(.horizontal, 16)

            SegmentedControl(selectedTab: $selectedTab, tabItems: settingsTabItems)
                .padding(.horizontal, 16)

            Group {
                switch selectedTab {
                case .general: GeneralSettingsView()
                case .security: SecuritySettingsView()
                case .advanced: AdvancedSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationBarHidden(true)
    }
}
