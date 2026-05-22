import SwiftUI
import WidgetKit

// MARK: - Wide layout (in-app + 343-wide carousel page + .systemMedium OS widget)

struct NewsWidgetWideContent: View {
    static let inAppContentHeight: CGFloat = 86

    let title: String
    let publisher: String
    let timeAgo: String
    let options: NewsWidgetOptions
    var titleLineLimit: Int = 2

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = WidgetPalette(renderingMode: renderingMode)
        VStack(alignment: .leading, spacing: 0) {
            if options.showTitle {
                TitleText(title, textColor: palette.title)
                    .lineLimit(titleLineLimit)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .widgetAccentable()
            }

            Spacer(minLength: 0)

            if options.showSource || options.showDate {
                HStack(alignment: .center, spacing: 8) {
                    if options.showSource {
                        BodySSBText(publisher, textColor: palette.accent)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if options.showDate {
                        BodySSBText(timeAgo, textColor: palette.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Compact layout (small carousel preview + .systemSmall OS widget)

struct NewsWidgetCompactContent: View {
    let title: String
    let timeAgo: String
    let options: NewsWidgetOptions

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = WidgetPalette(renderingMode: renderingMode)
        VStack(alignment: .leading, spacing: 0) {
            if options.showTitle {
                TitleText(title, textColor: palette.title)
                    .lineLimit(4)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .widgetAccentable()
            }

            Spacer(minLength: 8)

            if options.showDate {
                HStack {
                    Spacer(minLength: 0)
                    BodySSBText(timeAgo, textColor: palette.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
