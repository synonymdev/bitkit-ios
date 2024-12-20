//
//  AllActivityView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/18.
//

import SwiftUI

struct AllActivityView: View {
    @EnvironmentObject private var activity: ActivityListViewModel

    var body: some View {
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
        .navigationTitle("All Activity")
    }
}

#Preview {
    AllActivityView()
        .environmentObject(WalletViewModel())
}
