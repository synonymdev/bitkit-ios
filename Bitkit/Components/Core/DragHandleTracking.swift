import SwiftUI

/// Preference key for tracking drag handle location in a coordinate space.
/// Used so only the drag handle (e.g. burger icon) starts a reorder drag.
struct DragHandlePreferenceKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private struct DragHandleLocationModifier: ViewModifier {
    let coordinateSpace: String

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .preference(
                            key: DragHandlePreferenceKey.self,
                            value: [geometry.frame(in: .named(coordinateSpace))]
                        )
                }
            )
    }
}

public extension View {
    /// Reports this view's frame as the drag handle in the given coordinate space.
    /// Only touches that start inside this frame will begin a reorder drag.
    func trackDragHandle(in coordinateSpace: String = "dragSpace") -> some View {
        modifier(DragHandleLocationModifier(coordinateSpace: coordinateSpace))
    }
}
