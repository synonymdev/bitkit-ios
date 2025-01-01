//
//  AllActivityView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/18.
//

import SwiftUI

struct ActivityListFilter: View {
    @Binding var searchText: String
    
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)
            TextField("Search", text: $searchText)
            HStack(spacing: 12) {
                Image(systemName: "tag")
                Image(systemName: "calendar")
            }
            .foregroundColor(.gray)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
        .padding()
    }
}

struct AllActivityView: View {
    @EnvironmentObject private var activity: ActivityListViewModel
    @State private var searchText = ""
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            ActivityListFilter(searchText: $searchText)
            activityList
        }
        .navigationTitle("All Activity")
    }

    private var activityList: some View {
        ScrollView {
            if let items = activity.allActivities {
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
