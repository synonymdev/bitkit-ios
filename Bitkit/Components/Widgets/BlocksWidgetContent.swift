import SwiftUI
import WidgetKit

// Shared Bitcoin Blocks widget content, reused by the in-app feed, the carousel preview, and the
// home-screen WidgetKit extension. Colors adapt to `widgetRenderingMode` via ``WidgetPalette``.

// MARK: - Wide layout (in-app + 343-wide carousel page + .systemMedium / .systemLarge OS widget)

struct BlocksWidgetWideContent: View {
    static let inAppContentHeight: CGFloat = 124

    let data: CachedBlock
    let options: BlocksWidgetOptions

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = WidgetPalette(renderingMode: renderingMode)
        let fields = options.enabledFields
        let topAligned = fields.count <= 2
        VStack(alignment: .leading, spacing: topAligned ? 8 : 0) {
            ForEach(Array(fields.enumerated()), id: \.element) { index, field in
                if index > 0, !topAligned {
                    Spacer(minLength: 8)
                }
                BlocksWidgetWideRow(field: field, value: field.value(from: data), palette: palette)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct BlocksWidgetWideRow: View {
    let field: BlocksWidgetField
    let value: String
    let palette: WidgetPalette

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            BlocksWidgetIcon(field: field, palette: palette)

            BodyMText(field.label, textColor: palette.label)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            BodyMSBText(value, textColor: palette.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .widgetAccentable()
        }
    }
}

// MARK: - Compact layout (small carousel preview + .systemSmall OS widget)

struct BlocksWidgetCompactContent: View {
    let data: CachedBlock
    let options: BlocksWidgetOptions

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = WidgetPalette(renderingMode: renderingMode)
        let fields = options.enabledFields
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(fields.enumerated()), id: \.element) { _, field in
                HStack(alignment: .center, spacing: 8) {
                    BlocksWidgetIcon(field: field, palette: palette)

                    BodySSBText(field.value(from: data), textColor: palette.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .widgetAccentable()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Shared row icon

private struct BlocksWidgetIcon: View {
    let field: BlocksWidgetField
    let palette: WidgetPalette

    var body: some View {
        Image(field.iconName)
            .resizable()
            .renderingMode(.template)
            .foregroundColor(palette.accent)
            .frame(width: 20, height: 20)
            .widgetAccentable()
    }
}
