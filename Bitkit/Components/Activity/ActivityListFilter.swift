import SwiftUI

struct ActivityListFilter: View {
    @ObservedObject var viewModel: ActivityListViewModel
    @State private var showingDateRange = false
    @State private var showingTagSelector = false

    var body: some View {
        HStack(spacing: 0) {
            Image("magnifying-glass")
                .resizable()
                .frame(width: 24, height: 24)
                .foregroundColor(.white64)
            TextField("Search", text: $viewModel.searchText, backgroundColor: .clear, font: .custom(Fonts.regular, size: 17))
            HStack(spacing: 12) {
                Image("tag")
                    .resizable()
                    .frame(width: 24, height: 24)
                    .foregroundColor(!viewModel.selectedTags.isEmpty ? .brandAccent : .white64)
                    .onTapGesture {
                        showingTagSelector = true
                    }
                Image("calendar")
                    .resizable()
                    .frame(width: 24, height: 24)
                    .foregroundColor(viewModel.startDate != nil ? .brandAccent : .white64)
                    .onTapGesture {
                        showingDateRange = true
                    }
            }
            .foregroundColor(.gray)
        }
        .frame(height: 48)
        .padding(.horizontal)
        .background(Color.white10)
        .cornerRadius(32)
        .sheet(isPresented: $showingDateRange) {
            DateRangeSelector(viewModel: viewModel)
        }
        .sheet(isPresented: $showingTagSelector) {
            TagSelector(viewModel: viewModel)
        }
    }
}
