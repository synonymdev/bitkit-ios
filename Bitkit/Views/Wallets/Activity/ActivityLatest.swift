//
//  ActivityLatest.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/12/20.
//

import SwiftUI

struct ActivityLatest: View {
    let viewType: LatestActivityViewType

    enum LatestActivityViewType {
        case all
        case lightning
        case onchain
    }

    @EnvironmentObject private var activity: ActivityListViewModel

    var body: some View {
        switch viewType {
        case .all:
            return list(activity.latestActivities)
        case .lightning:
            return list(activity.lightningActivities)
        case .onchain:
            return list(activity.onchainActivities)
        }
    }

    @ViewBuilder
    func list(_ items: [Activity]?) -> some View {
        if let items {
            LazyVStack {
                ForEach(items, id: \.self) { item in
                    NavigationLink(destination: ActivityItemView(item: item)) {
                        ActivityRow(item: item)
                    }

                    if item != items.last {
                        Divider()
                    }
                }

                if items.count == 0 {
                    Text(localizedString("wallet__activity_no"))
                        .padding()
                } else {
                    CustomButton(title: localizedString("wallet__activity_show_all"), variant: .tertiary, destination: AllActivityView())
                }
            }
        } else {
            EmptyView()
        }
    }
}
