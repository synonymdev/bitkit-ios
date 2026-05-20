import SwiftUI
import WidgetKit

/// Centralizes the color convention shared between the in-app widget feed and the home-screen
/// WidgetKit extension, so a single content view renders correctly in full color **and** in
/// tinted/monochrome (Smart Stack) rendering.
///
/// Outside of a widget, `widgetRenderingMode` defaults to `.fullColor`, so in-app widgets get the
/// dark-theme palette automatically. In tinted/accented modes colors collapse to `.primary`/
/// `.secondary` so WidgetKit can recolor them, and the container background becomes clear.
struct WidgetPalette {
    let renderingMode: WidgetRenderingMode

    var isFullColor: Bool {
        renderingMode == .fullColor
    }

    /// Titles and primary values.
    var title: Color {
        isFullColor ? .white : .primary
    }

    /// Strong secondary labels (e.g. Blocks field labels, weather description).
    var label: Color {
        isFullColor ? .white80 : .secondary
    }

    /// Subtle metadata (price pair/period, news date, metric caption).
    var secondary: Color {
        isFullColor ? .white64 : .secondary
    }

    /// Icons and accent text (block icons, news source).
    var accent: Color {
        isFullColor ? .brandAccent : .primary
    }

    /// Container background — clear in tinted mode so the wallpaper shows through.
    var background: Color {
        isFullColor ? .gray6 : .clear
    }

    /// Data-driven colors (green/red change, weather condition). Falls back to `.primary` in
    /// tinted mode so the system can recolor consistently.
    func data(_ color: Color) -> Color {
        isFullColor ? color : .primary
    }
}
