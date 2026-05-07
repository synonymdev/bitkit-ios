import SwiftUI

// MARK: - In-app label override

/// In-app screens use the localized `widgets__widget__source` value for the Source field;
/// the OS widget uses the hardcoded English `BlocksWidgetField.label` since the widget
/// extension target does not have access to `LocalizeHelpers`.
extension BlocksWidgetField {
    var inAppLabel: String {
        if self == .showSource { return t("widgets__widget__source") }
        return label
    }
}

// MARK: - Widget

/// In-app Bitcoin Blocks widget (v61). Renders the wide layout — used inside the home feed
/// and the wide carousel page on the preview screen.
struct BlocksWidget: View {
    var options: BlocksWidgetOptions = .init()
    var isEditing: Bool = false
    var onEditingEnd: (() -> Void)?

    @StateObject private var viewModel = BlocksViewModel.shared

    init(
        options: BlocksWidgetOptions = BlocksWidgetOptions(),
        isEditing: Bool = false,
        onEditingEnd: (() -> Void)? = nil
    ) {
        self.options = options
        self.isEditing = isEditing
        self.onEditingEnd = onEditingEnd
    }

    var body: some View {
        BaseWidget(
            type: .blocks,
            isEditing: isEditing,
            onEditingEnd: onEditingEnd
        ) {
            content
        }
        .task {
            viewModel.startUpdates()
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.blockData == nil {
            WidgetContentBuilder.loadingView()
        } else if viewModel.error != nil && viewModel.blockData == nil {
            WidgetContentBuilder.errorView(t("widgets__blocks__error"))
        } else if let data = viewModel.blockData {
            BlocksWidgetWideContent(data: data, options: options)
        }
    }
}

// MARK: - Wide layout (in-app + 343-wide carousel page + .systemMedium / .systemLarge OS widget)

struct BlocksWidgetWideContent: View {
    let data: CachedBlock
    let options: BlocksWidgetOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(options.enabledFields, id: \.self) { field in
                BlocksWidgetWideRow(field: field, value: field.value(from: data))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BlocksWidgetWideRow: View {
    let field: BlocksWidgetField
    let value: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(field.iconName)
                .resizable()
                .renderingMode(.template)
                .foregroundColor(.brandAccent)
                .frame(width: 20, height: 20)

            BodyMText(field.inAppLabel, textColor: .white80)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            BodyMSBText(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Compact layout (small carousel preview + 163×192 OS small widget)

struct BlocksWidgetCompactContent: View {
    let data: CachedBlock
    let options: BlocksWidgetOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(options.compactFields, id: \.self) { field in
                HStack(alignment: .center, spacing: 8) {
                    Image(field.iconName)
                        .resizable()
                        .renderingMode(.template)
                        .foregroundColor(.brandAccent)
                        .frame(width: 20, height: 20)

                    BodySSBText(field.value(from: data))
                        .lineLimit(1)
                        .truncationMode(.middle)
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
    BlocksWidget()
        .padding()
        .background(.black)
        .environmentObject(WalletViewModel())
        .preferredColorScheme(.dark)
}
