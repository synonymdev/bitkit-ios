//
//  AllActivityView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/18.
//

import SwiftUI

struct AllActivityView: View {
    @EnvironmentObject private var activity: ActivityListViewModel
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            ActivityListFilter(viewModel: activity)
            activityList
        }
        .navigationTitle("All Activity")
    }

    private var activityList: some View {
        ScrollView {
            if let items = activity.filteredActivities {
                LazyVStack {
                    ForEach(items, id: \.self) { item in
                        NavigationLink(destination: ActivityItemView(item: item)) {
                            ActivityRow(item: item)

                            if item != items.last {
                                Divider()
                            }
                        }
                    }

                    VStack {}.frame(height: 120)
                }
            } else {
                Text("No activity")
                    .padding()
            }
        }
    }
}

#Preview {
    AllActivityView()
        .environmentObject(ActivityListViewModel())
}
