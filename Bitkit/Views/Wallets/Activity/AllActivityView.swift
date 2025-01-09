//
//  AllActivityView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/18.
//

import SwiftUI

struct DateRangeSelector: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: ActivityListViewModel
    @State private var startDate: Date
    @State private var endDate: Date
    
    init(viewModel: ActivityListViewModel) {
        self.viewModel = viewModel
        // Initialize with current dates or default to today
        _startDate = State(initialValue: viewModel.startDate ?? Calendar.current.startOfDay(for: Date()))
        _endDate = State(initialValue: viewModel.endDate ?? Date())
    }
    
    private func setDateRange(daysBack: Int) {
        let today = Date()
        let calendar = Calendar.current
        
        // Set end date to today
        endDate = today
        
        // Set start date to X days back at start of day
        if let daysBackDate = calendar.date(byAdding: .day, value: -daysBack, to: today) {
            startDate = calendar.startOfDay(for: daysBackDate)
        }
    }

    var body: some View {
        NavigationView {
            VStack {
                Form {
                    Section {
                        DatePicker("Start Date", selection: $startDate, displayedComponents: [.date])
                        DatePicker("End Date", selection: $endDate, displayedComponents: [.date])
                    }

                    Section {
                        Button("Today") {
                            setDateRange(daysBack: 0)
                            viewModel.startDate = startDate
                            viewModel.endDate = endDate
                            dismiss()
                        }
                        Button("Last 7 days") {
                            setDateRange(daysBack: 7)
                            viewModel.startDate = startDate
                            viewModel.endDate = endDate
                            dismiss()
                        }
                        Button("Last 30 days") {
                            setDateRange(daysBack: 30)
                            viewModel.startDate = startDate
                            viewModel.endDate = endDate
                            dismiss()
                        }
                        Button("Last 90 days") {
                            setDateRange(daysBack: 90)
                            viewModel.startDate = startDate
                            viewModel.endDate = endDate
                            dismiss()
                        }
                        Button("This year") {
                            let calendar = Calendar.current
                            startDate = calendar.date(from: calendar.dateComponents([.year], from: Date())) ?? Date()
                            endDate = Date()
                            viewModel.startDate = startDate
                            viewModel.endDate = endDate
                            dismiss()
                        }
                    } header: {
                        Text("Quick Select")
                    }
                }

                Spacer()

                HStack {
                    Spacer()
                    Button("Clear") {
                        viewModel.clearDateRange()
                        dismiss()
                    }
                    Spacer()
                    Button("Apply") {
                        viewModel.startDate = startDate
                        viewModel.endDate = endDate
                        dismiss()
                    }
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Date Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct TagSelector: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: ActivityListViewModel
    
    var body: some View {
        NavigationView {
            VStack {
                if viewModel.availableTags.isEmpty {
                    Text("No tags found")
                        .foregroundColor(.gray)
                        .padding()
                } else {
                    List {
                        ForEach(viewModel.availableTags, id: \.self) { tag in
                            Button(action: {
                                if viewModel.selectedTags.contains(tag) {
                                    viewModel.selectedTags.remove(tag)
                                } else {
                                    viewModel.selectedTags.insert(tag)
                                }
                            }) {
                                HStack {
                                    Text(tag)
                                    Spacer()
                                    if viewModel.selectedTags.contains(tag) {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.orange)
                                    }
                                }
                            }
                        }
                    }
                }
                
                Spacer()
                // Bottom buttons
                HStack {
                    Spacer()
                    Button("Clear") {
                        viewModel.clearTags()
                        dismiss()
                    }
                    Spacer()
                    Button("Apply") {
                        dismiss()
                    }
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Select Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct ActivityListFilter: View {
    @ObservedObject var viewModel: ActivityListViewModel
    @State private var showingDateRange = false
    @State private var showingTagSelector = false

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)
            TextField("Search", text: $viewModel.searchText)
            HStack(spacing: 12) {
                Image(systemName: "tag")
                    .foregroundColor(!viewModel.selectedTags.isEmpty ? .orange : .gray)
                    .onTapGesture {
                        showingTagSelector = true
                    }
                Image(systemName: "calendar")
                    .foregroundColor(viewModel.startDate != nil ? .orange : .gray)
                    .onTapGesture {
                        showingDateRange = true
                    }
            }
            .foregroundColor(.gray)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
        .padding()
        .sheet(isPresented: $showingDateRange) {
            DateRangeSelector(viewModel: viewModel)
        }
        .sheet(isPresented: $showingTagSelector) {
            TagSelector(viewModel: viewModel)
        }
    }
}

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
