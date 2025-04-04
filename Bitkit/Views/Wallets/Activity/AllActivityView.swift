//
//  AllActivityView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/18.
//

import SwiftUI

struct AllActivityView: View {
    @EnvironmentObject private var activity: ActivityListViewModel
    @State private var selectedTab = ActivityTab.all

    enum ActivityTab {
        case all, sent, received, other

        var title: String {
            switch self {
            case .all: return "All"
            case .sent: return "Sent"
            case .received: return "Received"
            case .other: return "Other"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ActivityListFilter(viewModel: activity)

            Picker("Activity Type", selection: $selectedTab) {
                ForEach([ActivityTab.all, .sent, .received, .other], id: \.self) { tab in
                    Text(tab.title)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

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
                    .padding(.horizontal)
                } else {
                    Text("No activity")
                        .padding()
                }
            }
            .dismissKeyboardOnScroll()
        }
        .navigationTitle("All Activity")
    }
}

#Preview {
    AllActivityView()
        .environmentObject(ActivityListViewModel())
        .preferredColorScheme(.dark)
}
