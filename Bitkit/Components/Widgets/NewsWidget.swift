import SwiftUI

/// Options for configuring the NewsWidget
struct NewsWidgetOptions: Codable, Equatable {
    var showDate: Bool = true
    var showTitle: Bool = true
    var showSource: Bool = true
}

/// A widget that displays a news article
struct NewsWidget: View {
    /// Configuration options for the widget
    var options: NewsWidgetOptions = NewsWidgetOptions()

    /// Flag indicating if the widget is in editing mode
    var isEditing: Bool = false

    /// Callback to signal when editing should end
    var onEditingEnd: (() -> Void)?

    /// View model for handling news data
    @StateObject private var viewModel = NewsViewModel.shared

    /// Initialize the widget
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
            VStack(spacing: 0) {
                if viewModel.isLoading {
                    WidgetContentBuilder.loadingView()
                } else if viewModel.error != nil {
                    WidgetContentBuilder.errorView(localizedString("widgets__news__error"))
                } else if let data = viewModel.widgetData {
                    if options.showDate {
                        BodyMText(data.timeAgo, textColor: .textPrimary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 16)
                    }

                    if options.showTitle {
                        TitleText(data.title)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if options.showSource {
                        WidgetContentBuilder.sourceRow(source: data.publisher)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !isEditing, let data = viewModel.widgetData, let url = URL(string: data.link) {
                    UIApplication.shared.open(url)
                }
            }
        }
        .onAppear {
            viewModel.startUpdates()
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
