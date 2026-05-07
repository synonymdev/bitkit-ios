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
            NewsWidgetWideContent(data: data, options: options)
        }
    }
}

// MARK: - Wide layout (in-app + 343-wide carousel page)

struct NewsWidgetWideContent: View {
    let data: WidgetData
    let options: NewsWidgetOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if options.showTitle {
                TitleText(data.title)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if options.showSource || options.showDate {
                HStack(alignment: .center, spacing: 8) {
                    if options.showSource {
                        BodySSBText(data.publisher, textColor: .brandAccent)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if options.showDate {
                        BodySSBText(data.timeAgo, textColor: .textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Compact layout (small carousel preview + 163×192 OS widget)

struct NewsWidgetCompactContent: View {
    let data: WidgetData
    let options: NewsWidgetOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if options.showTitle {
                TitleText(data.title)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 8)

            if options.showDate {
                HStack {
                    Spacer(minLength: 0)
                    BodySSBText(data.timeAgo, textColor: .textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.gray6)
        .cornerRadius(16)
    }
}

#Preview {
    NewsWidget()
        .padding()
        .background(.black)
        .environmentObject(WalletViewModel())
        .preferredColorScheme(.dark)
}
