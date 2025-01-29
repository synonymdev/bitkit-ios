import SwiftUI

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
                    .foregroundColor(!viewModel.selectedTags.isEmpty ? .brandAccent : .gray)
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