import SwiftUI
import WidgetKit

// MARK: - Entry

struct BlocksWidgetEntry: TimelineEntry {
    let date: Date
    let blockData: BlockData?
    /// True when the timeline could not load data and there is nothing in cache.
    let showsError: Bool
    /// Mirrored from in-app blocks widget settings (App Group).
    let options: BlocksWidgetOptions
}

// MARK: - Timeline Provider

struct BlocksWidgetProvider: TimelineProvider {
    static let previewBlockData = BlockData(
        hash: "0000000000000000000000000000000000000000000000000000000000000000",
        difficulty: "0.00",
        size: "0 KB",
        weight: "0 MWU",
        height: "900,000",
        time: "12:00:00 PM",
        date: "4/10/26",
        transactionCount: "1024",
        merkleRoot: "0000000000000000000000000000000000000000000000000000000000000000"
    )

    func placeholder(in _: Context) -> BlocksWidgetEntry {
        BlocksWidgetEntry(date: Date(), blockData: Self.previewBlockData, showsError: false, options: BlocksWidgetOptions())
    }

    func getSnapshot(in context: Context, completion: @escaping (BlocksWidgetEntry) -> Void) {
        let options = BlocksHomeScreenWidgetOptionsStore.load()

        if context.isPreview {
            completion(BlocksWidgetEntry(date: Date(), blockData: Self.previewBlockData, showsError: false, options: options))
            return
        }
        let cached = BlocksService.shared.getCachedData()
        completion(BlocksWidgetEntry(date: Date(), blockData: cached, showsError: false, options: options))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<BlocksWidgetEntry>) -> Void) {
        let options = BlocksHomeScreenWidgetOptionsStore.load()

        Task {
            let entry: BlocksWidgetEntry
            do {
                let data = try await BlocksService.shared.fetchBlockData(returnCachedImmediately: false)
                entry = BlocksWidgetEntry(date: Date(), blockData: data, showsError: false, options: options)
            } catch {
                let cached = BlocksService.shared.getCachedData()
                entry = BlocksWidgetEntry(date: Date(), blockData: cached, showsError: cached == nil, options: options)
            }

            let nextRefresh = Calendar.current.date(byAdding: .minute, value: 20, to: Date()) ?? Date().addingTimeInterval(1200)
            let timeline = Timeline(entries: [entry], policy: .after(nextRefresh))
            completion(timeline)
        }
    }
}

// MARK: - View

struct BlocksHomeScreenWidgetEntryView: View {
    @Environment(\.widgetFamily) var widgetFamily
    @Environment(\.widgetRenderingMode) var widgetRenderingMode

    var entry: BlocksWidgetProvider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // HStack {
            //     Image("blocks-widget")
            //         .resizable()
            //         .frame(width: 32, height: 32)

            //     BodyMSBText("Latest block", textColor: titleColor)
            //         .lineLimit(1)

            //     Spacer()
            // }

            if entry.showsError, entry.blockData == nil {
                Text("Couldn’t load block data.")
                    .font(Fonts.medium(size: bodyFontSize))
                    .foregroundColor(secondaryTextColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let data = entry.blockData {
                blockDataContent(data: data)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .containerBackground(for: .widget) {
            backgroundView
        }
    }

    private var backgroundView: some View {
        widgetRenderingMode == .fullColor ? Color.gray6 : Color.clear
    }

    @ViewBuilder
    private func blockDataContent(data: BlockData) -> some View {
        let allRows = entry.options.displayRows(for: data)
        let visibleRows = Array(allRows.prefix(maxVisibleBlockRows))

        VStack(spacing: 0) {
            if visibleRows.isEmpty {
                Text("Choose fields in Bitkit (blocks widget).")
                    .font(Fonts.medium(size: bodyFontSize))
                    .foregroundColor(secondaryTextColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ForEach(visibleRows, id: \.key) { item in
                    blockRow(label: item.label, value: item.value)
                }

                if allRows.count > visibleRows.count {
                    CaptionBText("+\(allRows.count - visibleRows.count) more in Bitkit", textColor: secondaryTextColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            }
        }

        Spacer(minLength: 0)

        if entry.options.showSource, !visibleRows.isEmpty {
            HStack {
                Spacer()
                CaptionBText("mempool.space", textColor: secondaryTextColor)
            }
        }
    }

    private var secondaryTextColor: Color {
        widgetRenderingMode == .fullColor ? .white.opacity(0.64) : .secondary
    }

    private var valueTextColor: Color {
        widgetRenderingMode == .fullColor ? .white : .primary
    }

    private var bodyFontSize: CGFloat {
        switch widgetFamily {
        case .systemSmall: 14
        case .systemMedium: 15
        case .systemLarge, .systemExtraLarge: 16
        default: 14
        }
    }

    /// Home screen widgets do not scroll; cap rows and point users to Bitkit for the rest.
    private var maxVisibleBlockRows: Int {
        switch widgetFamily {
        case .systemSmall: 3
        case .systemMedium: 4
        case .systemLarge, .systemExtraLarge: 11
        default: 4
        }
    }

    private func blockRow(label: String, value: String) -> some View {
        HStack(spacing: 0) {
            BodySSBText(label, textColor: secondaryTextColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(value)
                .font(Fonts.semiBold(size: bodyFontSize))
                .foregroundColor(valueTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(minHeight: rowMinHeight)
    }

    private var rowMinHeight: CGFloat {
        switch widgetFamily {
        case .systemSmall: 22
        case .systemMedium, .systemLarge, .systemExtraLarge: 26
        default: 22
        }
    }
}

// MARK: - Widget Configuration

struct BitkitBlocksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: BlocksService.blocksHomeScreenWidgetKind, provider: BlocksWidgetProvider()) { entry in
            BlocksHomeScreenWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Bitcoin Blocks")
        .description("Latest block data from the Bitcoin chain. Rows match the blocks widget in Bitkit.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
