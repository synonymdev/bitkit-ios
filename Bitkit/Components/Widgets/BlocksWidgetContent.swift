import SwiftUI
import WidgetKit

// Shared Bitcoin Blocks widget content, reused by the in-app feed, the carousel preview, and the
// home-screen WidgetKit extension. Colors adapt to `widgetRenderingMode` via ``WidgetPalette``.

private let blocksRowSpacings: [CGFloat] = [16, 10, 6, 2]

// MARK: - Wide layout (in-app + 343-wide carousel page + .systemMedium / .systemLarge OS widget)

struct BlocksWidgetWideContent: View {
    let data: CachedBlock
    let options: BlocksWidgetOptions

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        ViewThatFits(in: .vertical) {
            ForEach(blocksRowSpacings, id: \.self) { spacing in
                stack(spacing: spacing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func stack(spacing: CGFloat) -> some View {
        let palette = WidgetPalette(renderingMode: renderingMode)
        return VStack(alignment: .leading, spacing: spacing) {
            ForEach(options.enabledFields, id: \.self) { field in
                BlocksWidgetWideRow(field: field, value: field.value(from: data), palette: palette)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
        ViewThatFits(in: .vertical) {
            ForEach(blocksRowSpacings, id: \.self) { spacing in
                stack(spacing: spacing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func stack(spacing: CGFloat) -> some View {
        let palette = WidgetPalette(renderingMode: renderingMode)
        return VStack(alignment: .leading, spacing: spacing) {
            ForEach(options.enabledFields, id: \.self) { field in
                HStack(alignment: .center, spacing: 8) {
                    BlocksWidgetIcon(field: field, palette: palette)

                    BodySSBText(field.value(from: data), textColor: palette.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .widgetAccentable()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
