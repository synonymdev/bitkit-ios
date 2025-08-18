import SwiftUI

/// Preference key for tracking button locations in a coordinate space
struct ButtonLocationPreferenceKey: PreferenceKey {
    public static var defaultValue: [CGRect] = []

    public static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

/// Modifier that tracks a view's location in a specified coordinate space
private struct ButtonLocationModifier: ViewModifier {
    /// The name of the coordinate space to track the view in
    let coordinateSpace: String

    /// Callback when the view's location changes
    let onLocationChanged: (CGRect) -> Void

    public init(coordinateSpace: String, onLocationChanged: @escaping (CGRect) -> Void) {
        self.coordinateSpace = coordinateSpace
        self.onLocationChanged = onLocationChanged
    }

    public func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .preference(
                            key: ButtonLocationPreferenceKey.self,
                            value: [geometry.frame(in: .named(coordinateSpace))]
                        )
                        .onPreferenceChange(ButtonLocationPreferenceKey.self) { frames in
                            if let frame = frames.first {
                                onLocationChanged(frame)
                            }
                        }
                }
            )
    }
}

public extension View {
    /// Tracks the location of a view in a specified coordinate space
    /// - Parameters:
    ///   - coordinateSpace: The name of the coordinate space to track the view in
    ///   - onLocationChanged: Callback when the view's location changes
    /// - Returns: A view that tracks its location in the specified coordinate space
    func trackButtonLocation(
        in coordinateSpace: String,
        onLocationChanged: @escaping (CGRect) -> Void
    ) -> some View {
        modifier(
            ButtonLocationModifier(
                coordinateSpace: coordinateSpace,
                onLocationChanged: onLocationChanged
            )
        )
    }

    /// Tracks the location of a view in the default "dragSpace" coordinate space
    /// - Parameter onLocationChanged: Callback when the view's location changes
    /// - Returns: A view that tracks its location in the drag space
    func trackButtonLocation(onLocationChanged: @escaping (CGRect) -> Void) -> some View {
        trackButtonLocation(in: "dragSpace", onLocationChanged: onLocationChanged)
    }
}
