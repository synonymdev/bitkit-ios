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
                .foregroundColor(!viewModel.searchText.isEmpty ? .brandAccent : .white64)
            TextField("Search", text: $viewModel.searchText, backgroundColor: .clear, font: .custom(Fonts.regular, size: 17))
                .frame(width: 120)
                .offset(x: -5)

            HStack(alignment: .center, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .center, spacing: 4) {
                        Spacer()
                        ForEach(Array(viewModel.selectedTags), id: \.self) { tag in
                            Tag(tag, icon: .close, onDelete: {
                                viewModel.selectedTags.remove(tag)
                            })
                        }
                    }
                    // TODO: uncomment after bump to iOS 18
                    // .containerRelativeFrame(.horizontal, alignment: .trailing)
                }
                .frame(maxWidth: .infinity)

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
        }
        .frame(width: .infinity, height: 48)
        .padding(.horizontal)
        .background(Color.gray6)
        .cornerRadius(32)
        .sheet(isPresented: $showingDateRange) {
            DateRangeSelectorSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showingTagSelector) {
            TagFilterSheet(viewModel: viewModel, isPresented: $showingTagSelector)
        }
    }
}
