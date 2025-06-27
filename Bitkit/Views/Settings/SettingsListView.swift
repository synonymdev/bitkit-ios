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
        ScrollView {
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

            NavigationLink(destination: Text("Coming soon")) {
                SettingsListLabel(
                    title: NSLocalizedString("settings__backup_title", comment: ""),
                    iconName: "settings-clock"
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

            // TODO: add to subview
            // NavigationLink(destination: LightningSettingsView()) {
            //     Label {
            //         Text("Lightning")
            //     } icon: {
            //         Image(systemName: "bolt.fill")
            //     }
            // }

            // NavigationLink(destination: ChannelOrders()) {
            //     Label {
            //         Text("Channel Orders")
            //     } icon: {
            //         Image(systemName: "list.bullet.rectangle")
            //     }
            // }

            // NavigationLink(destination: LogView()) {
            //     Label {
            //         Text("Logs")
            //     } icon: {
            //         Image(systemName: "doc.text.fill")
            //     }
            // }
        }
        .navigationTitle(NSLocalizedString("settings__settings", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .overlay(
            VStack {
                Spacer()
                Image("cog")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 256)
                    .padding()
                    .onTapGesture {
                        cogTapCount += 1

                        // Toggle dev settings every 5 taps
                        if cogTapCount >= 5 {
                            showDevSettings.toggle()
                            cogTapCount = 0
                        }
                    }
                Spacer()
                    .frame(height: 32)
            }
            .ignoresSafeArea(.container, edges: .bottom)
        )
    }
}

#Preview {
    SettingsListView()
        .environmentObject(WalletViewModel())
        .environmentObject(AppViewModel())
        .environmentObject(ActivityListViewModel())
        .preferredColorScheme(.dark)
}
