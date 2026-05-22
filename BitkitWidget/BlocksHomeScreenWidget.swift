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

    private var palette: WidgetPalette {
        WidgetPalette(renderingMode: widgetRenderingMode)
    }

    var body: some View {
        content
            .containerBackground(for: .widget) { palette.background }
    }

    @ViewBuilder
    private var content: some View {
        if entry.showsError {
            errorView
        } else if let block = entry.block {
            switch widgetFamily {
            case .systemSmall:
                BlocksWidgetCompactContent(data: block, options: entry.options)
            default:
                BlocksWidgetWideContent(data: block, options: entry.options)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var errorView: some View {
        BodySText(t("widgets__blocks__error"), textColor: palette.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
