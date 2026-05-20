import SwiftUI
import WidgetKit

// MARK: - Entry

struct BlocksWidgetEntry: TimelineEntry {
    let date: Date
    let block: CachedBlock?
    let options: BlocksWidgetOptions
    /// True when no fresh data could be fetched and there is nothing in cache to fall back to.
    let showsError: Bool
}

// MARK: - Helpers

private enum BlocksWidgetEntryBuilder {
    static let refreshInterval: TimeInterval = 15 * 60
}

// MARK: - Timeline Provider

struct BlocksWidgetProvider: TimelineProvider {
    /// Stable mock for widget gallery / placeholder snapshots.
    private static let mockBlock = CachedBlock(
        height: "870,123",
        time: "01:31:42 UTC",
        date: "11/2/2024",
        transactionCount: "2,175",
        size: "1,606 KB",
        fees: "25,059,357"
    )

    private static let mockEntry = BlocksWidgetEntry(
        date: Date(),
        block: mockBlock,
        options: BlocksWidgetOptions(),
        showsError: false
    )

    func placeholder(in _: Context) -> BlocksWidgetEntry {
        Self.mockEntry
    }

    func getSnapshot(in context: Context, completion: @escaping (BlocksWidgetEntry) -> Void) {
        let options = BlocksHomeScreenWidgetOptionsStore.load()

        if context.isPreview {
            completion(BlocksWidgetEntry(
                date: Self.mockEntry.date,
                block: Self.mockBlock,
                options: options,
                showsError: false
            ))
            return
        }

        let cached = BlocksWidgetService.cachedLatest()
        completion(BlocksWidgetEntry(
            date: Date(),
            block: cached,
            options: options,
            showsError: false
        ))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<BlocksWidgetEntry>) -> Void) {
        let options = BlocksHomeScreenWidgetOptionsStore.load()

        Task {
            let entry: BlocksWidgetEntry
            do {
                let fresh = try await BlocksWidgetService.fetchFreshLatest()
                entry = BlocksWidgetEntry(date: Date(), block: fresh, options: options, showsError: false)
            } catch {
                if let cached = BlocksWidgetService.cachedLatest() {
                    entry = BlocksWidgetEntry(date: Date(), block: cached, options: options, showsError: false)
                } else {
                    entry = BlocksWidgetEntry(date: Date(), block: nil, options: options, showsError: true)
                }
            }

            let nextRefresh = Date().addingTimeInterval(BlocksWidgetEntryBuilder.refreshInterval)
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }
}

// MARK: - View

struct BlocksHomeScreenWidgetEntryView: View {
    @Environment(\.widgetFamily) var widgetFamily
    @Environment(\.widgetRenderingMode) var widgetRenderingMode

    var entry: BlocksWidgetProvider.Entry

    var body: some View {
        content
            .containerBackground(for: .widget) { backgroundView }
    }

    @ViewBuilder
    private var content: some View {
        if entry.showsError {
            errorView
        } else if let block = entry.block {
            switch widgetFamily {
            case .systemSmall:
                compactLayout(block: block)
            default:
                wideLayout(block: block, fields: entry.options.enabledFields)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    // MARK: - Layouts

    /// Compact (`.systemSmall`): icon + value rows for the selected fields.
    private func compactLayout(block: CachedBlock) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(entry.options.enabledFields, id: \.self) { field in
                HStack(alignment: .center, spacing: 8) {
                    iconImage(field: field)
                    Text(field.value(from: block))
                        .font(Fonts.semiBold(size: 15))
                        .foregroundColor(titleTextColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .widgetAccentable()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Wide layout (`.systemMedium`): icon + label + value rows for the selected fields.
    private func wideLayout(block: CachedBlock, fields: [BlocksWidgetField]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(fields, id: \.self) { field in
                HStack(alignment: .center, spacing: 8) {
                    iconImage(field: field)
                    Text(field.label)
                        .font(Fonts.regular(size: 17))
                        .foregroundColor(labelTextColor)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(field.value(from: block))
                        .font(Fonts.semiBold(size: 17))
                        .foregroundColor(titleTextColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .widgetAccentable()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func iconImage(field: BlocksWidgetField) -> some View {
        Image(field.iconName)
            .resizable()
            .renderingMode(.template)
            .foregroundColor(iconColor)
            .frame(width: 20, height: 20)
            .widgetAccentable()
    }

    private var errorView: some View {
        Text("Couldn’t load blocks data.")
            .font(Fonts.regular(size: 13))
            .foregroundColor(labelTextColor)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Colors

    private var backgroundView: some View {
        widgetRenderingMode == .fullColor ? Color.gray6 : Color.clear
    }

    private var titleTextColor: Color {
        widgetRenderingMode == .fullColor ? .white : .primary
    }

    private var labelTextColor: Color {
        widgetRenderingMode == .fullColor ? .white.opacity(0.8) : .secondary
    }

    private var iconColor: Color {
        widgetRenderingMode == .fullColor ? .brandAccent : .primary
    }
}

// MARK: - Widget Configuration

struct BitkitBlocksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: BlocksHomeScreenWidgetOptionsStore.blocksHomeScreenWidgetKind,
            provider: BlocksWidgetProvider()
        ) { entry in
            BlocksHomeScreenWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(t("widgets__blocks__name"))
        .description(t("widgets__blocks__description"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
