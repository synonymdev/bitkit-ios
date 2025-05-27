//
//  ActivityLatest.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/12/20.
//

import SwiftUI

struct ActivityLatest: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject private var activity: ActivityListViewModel

    var body: some View {
        VStack(spacing: 0) {
            CaptionText(localizedString("wallet__activity"))
                .textCase(.uppercase)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 16)
                .padding(.top, 32)

            if let items = activity.latestActivities {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(items, id: \.self) { item in
                        NavigationLink(value: Route.activityDetail(item)) {
                            ActivityRow(item: item)
                        }

                        if item != items.last {
                            Divider()
                        }
                    }

                    if items.count == 0 {
                        Button(
                            action: {
                                app.showReceiveSheet = true
                                Haptics.play(.openSheet)
                            },
                            label: {
                                EmptyActivityRow()
                            })
                    } else {
                        CustomButton(title: localizedString("wallet__activity_show_all"), variant: .tertiary) {
                            navigation.navigate(.activityList)
                        }
                    }
                }
            } else {
                EmptyView()
            }
        }
    }
}
