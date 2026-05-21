import SwiftUI

/// A widget that displays a news article.
struct NewsWidget: View {
    var options: NewsWidgetOptions = .init()
    var isEditing: Bool = false
    var onEditingEnd: (() -> Void)?

    @StateObject private var viewModel = NewsViewModel.shared

    init(
        options: NewsWidgetOptions = NewsWidgetOptions(),
        isEditing: Bool = false,
        onEditingEnd: (() -> Void)? = nil
    ) {
        self.options = options
        self.isEditing = isEditing
        self.onEditingEnd = onEditingEnd
    }

    var body: some View {
        BaseWidget(
            type: .news,
            isEditing: isEditing,
            onEditingEnd: onEditingEnd
        ) {
            content
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isEditing, let data = viewModel.widgetData, let url = URL(string: data.link) {
                        UIApplication.shared.open(url)
                    }
                }
        }
        .task {
            viewModel.startUpdates()
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.widgetData == nil {
            WidgetContentBuilder.loadingView()
        } else if viewModel.error != nil {
            WidgetContentBuilder.errorView(t("widgets__news__error"))
        } else if let data = viewModel.widgetData {
            NewsWidgetWideContent(
                title: data.title,
                publisher: data.publisher,
                timeAgo: data.timeAgo,
                options: options
            )
            .frame(height: NewsWidgetWideContent.inAppContentHeight)
        }
    }
}

#Preview {
    NewsWidget()
        .padding()
        .background(.black)
        .environmentObject(WalletViewModel())
        .preferredColorScheme(.dark)
}
