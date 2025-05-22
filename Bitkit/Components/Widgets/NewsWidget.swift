import SwiftUI

/// Options for configuring the NewsWidget
struct NewsWidgetOptions {
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

    /// View model for handling news data
    @StateObject private var viewModel = NewsViewModel.shared

    /// Flag to skip automatic loading for preview/testing
    @State private var skipLoading: Bool = false

    /// Initialize the widget
    init(
        options: NewsWidgetOptions = NewsWidgetOptions(),
        isEditing: Bool = false,
    ) {
        self.options = options
        self.isEditing = isEditing
    }

    /// Initialize with a custom view model (for previews)
    init(
        viewModel: NewsViewModel,
        options: NewsWidgetOptions = NewsWidgetOptions(),
        isEditing: Bool = false,
        skipLoading: Bool = true
    ) {
        self.options = options
        self.isEditing = isEditing
        self._viewModel = StateObject(wrappedValue: viewModel)
        self._skipLoading = State(initialValue: skipLoading)
    }

    var body: some View {
        BaseWidget(
            id: "news",
            isEditing: isEditing
        ) {
            VStack(spacing: 0) {
                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.error != nil {
                    CaptionBText("Failed to load news")
                        .foregroundColor(.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                        HStack(spacing: 0) {
                            HStack {
                                CaptionBText(localizedString("widgets__widget__source"))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            HStack {
                                CaptionBText(data.publisher)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(.top, 16)
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
    }
}

#Preview("Default") {
    NewsWidget()
        .padding()
        .background(Color.black)
        .environmentObject(WalletViewModel())
        .environmentObject(WidgetStore())
        .preferredColorScheme(.dark)
}

#Preview("Custom") {
    NewsWidget(
        options: NewsWidgetOptions(showDate: false, showSource: false)
    )
    .padding()
    .background(Color.black)
    .environmentObject(WalletViewModel())
    .environmentObject(WidgetStore())
    .preferredColorScheme(.dark)
}

#Preview("Loading") {
    NewsWidget(
        viewModel: {
            let vm = NewsViewModel(preview: true)
            vm.isLoading = true
            vm.widgetData = nil
            vm.error = nil
            return vm
        }(),
        skipLoading: true
    )
    .padding()
    .background(Color.black)
    .environmentObject(WalletViewModel())
    .environmentObject(WidgetStore())
    .preferredColorScheme(.dark)
}

#Preview("Error") {
    NewsWidget(
        viewModel: {
            let vm = NewsViewModel(preview: true)
            vm.isLoading = false
            vm.widgetData = nil
            vm.error = NSError(domain: "NewsWidgetPreview", code: 404, userInfo: [NSLocalizedDescriptionKey: "Test error message"])
            return vm
        }(),
        skipLoading: true
    )
    .padding()
    .background(Color.black)
    .environmentObject(WalletViewModel())
    .environmentObject(WidgetStore())
    .preferredColorScheme(.dark)
}

#Preview("Editing") {
    NewsWidget(
        isEditing: true
    )
    .padding()
    .background(Color.black)
    .environmentObject(WalletViewModel())
    .environmentObject(WidgetStore())
    .preferredColorScheme(.dark)
}
