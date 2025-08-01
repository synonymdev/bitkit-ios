//
//  SettingsListView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import SwiftUI

struct SettingsListView: View {
    @EnvironmentObject var wallet: WalletViewModel
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var activity: ActivityListViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var widgets: WidgetsViewModel

    @AppStorage("showDevSettings") private var showDevSettings = Env.isDebug
    @State private var cogTapCount = 0

    var body: some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    NavigationLink(value: Route.generalSettings) {
                        SettingsListLabel(
                            title: NSLocalizedString("settings__general_title", comment: ""),
                            iconName: "settings-gear"
                        )
                    }

                    NavigationLink(destination: SecurityPrivacySettingsView()) {
                        SettingsListLabel(
                            title: NSLocalizedString("settings__security_title", comment: ""),
                            iconName: "settings-shield"
                        )
                    }

                    NavigationLink(destination: AdvancedSettingsView()) {
                        SettingsListLabel(
                            title: NSLocalizedString("settings__advanced_title", comment: ""),
                            iconName: "settings-slider"
                        )
                    }

                    NavigationLink(destination: SupportView()) {
                        SettingsListLabel(
                            title: NSLocalizedString("settings__support_title", comment: ""),
                            iconName: "settings-chat"
                        )
                    }

                    NavigationLink(destination: AboutView()) {
                        SettingsListLabel(
                            title: NSLocalizedString("settings__about_title", comment: ""),
                            iconName: "settings-info"
                        )
                    }

                    if showDevSettings {
                        NavigationLink(destination: DevSettingsView()) {
                            SettingsListLabel(
                                title: NSLocalizedString("settings__dev_title", comment: ""),
                                iconName: "settings-gear" //TODO: find icon for this
                            )
                        }
                    }

                    Spacer()
                        .frame(minHeight: 32)

                    Image("cog")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 256, height: 256)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .onTapGesture {
                            cogTapCount += 1

                            // Toggle dev settings every 5 taps
                            if cogTapCount >= 5 {
                                showDevSettings.toggle()
                                cogTapCount = 0

                                app.toast(
                                    type: .success,
                                    title: localizedString(showDevSettings ? "settings__dev_enabled_title" : "settings__dev_disabled_title"),
                                    description: localizedString(showDevSettings ? "settings__dev_enabled_message" : "settings__dev_disabled_message")
                                )
                            }
                        }

                    Spacer()
                        .frame(minHeight: 32)
                }
                .frame(minHeight: geometry.size.height)
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle(NSLocalizedString("settings__settings", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    SettingsListView()
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
        .environmentObject(ActivityListViewModel())
        .preferredColorScheme(.dark)
}
