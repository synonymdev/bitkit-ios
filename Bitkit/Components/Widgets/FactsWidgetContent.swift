import SwiftUI
import WidgetKit

// Shared Bitcoin Facts widget content, reused by the in-app feed, the carousel preview, and the
// home-screen WidgetKit extension. Colors and the Bitcoin badge adapt to `widgetRenderingMode`
// via ``WidgetPalette``. Card chrome is supplied by the caller.

// MARK: - Wide layout (in-app + 343-wide carousel page + .systemMedium OS widget)

struct FactsWidgetWideContent: View {
    let fact: String

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = WidgetPalette(renderingMode: renderingMode)
        HStack(alignment: .top, spacing: 32) {
            TitleText(fact, textColor: palette.title)
                .lineLimit(4)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
                .widgetAccentable()

            BitcoinLogo()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Compact layout (small carousel preview + .systemSmall OS widget)

struct FactsWidgetCompactContent: View {
    let fact: String

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = WidgetPalette(renderingMode: renderingMode)
        BodyMSBText(fact, textColor: palette.title)
            .lineLimit(4)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetAccentable()
            .overlay(alignment: .bottomTrailing) {
                BitcoinLogo()
            }
    }
}

// MARK: - Bitcoin badge

/// Orange ₿ badge in full color; a white circle with the glyph knocked out in tinted/monochrome
/// mode so it reads against the system wallpaper. `bitcoin` is a template glyph asset.
struct BitcoinLogo: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Group {
            if renderingMode == .fullColor {
                ZStack {
                    Circle()
                        .fill(Color.bitcoin)

                    glyph
                        .foregroundColor(.white)
                }
            } else {
                ZStack {
                    Circle()
                        .fill(Color.white)

                    glyph
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            }
        }
        .frame(width: 32, height: 32)
        .widgetAccentable()
    }

    private var glyph: some View {
        Image("bitcoin")
            .resizable()
            .renderingMode(.template)
    }
}
