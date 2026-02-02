import SwiftUI

/// Generic wrapper that adds drag and drop reordering functionality to any view
struct DraggableItem<Content: View, ID: Hashable>: View {
    /// Unique identifier for the item
    let id: ID

    /// Flag indicating if drag and drop is enabled
    let enableDrag: Bool

    /// Flag indicating if this item is currently being dragged
    let isDragging: Bool

    /// Content to be rendered inside the draggable wrapper
    let content: Content

    /// Number of items in the list
    private let itemCount: Int

    /// Item's original position in the list
    private let originalIndex: Int

    /// Height of each item including spacing
    private let itemHeight: CGFloat

    /// Long-press duration on burger before drag activates (avoids scroll conflict)
    private let longPressDuration: Double = 0.3

    /// Called when a drag operation begins
    let onDragBegan: () -> Void

    /// Called continuously as the drag progresses with the current drag amount
    let onDragChanged: (CGSize) -> Void

    /// Called when the drag ends with the final drag amount
    let onDragEnded: (CGSize) -> Void

    /// Current drag offset
    @State private var dragOffset = CGSize.zero

    /// Track if we should handle the drag
    @State private var shouldHandleDrag = false

    /// Track drag handle locations (e.g. burger icon); only drag starts from these
    @State private var dragHandleFrames: [CGRect] = []

    /// Frozen overlay frame during drag so overlay position doesn't change and cause jitter
    @State private var overlayFrameDuringDrag: CGRect?

    /// Coordinate space name used for preference (must match content)
    private let dragSpaceName = "dragSpace"

    /// Clamp vertical drag to list bounds (can't drag above first or below last item).
    private func constrainVerticalOffset(_ vertical: CGFloat) -> CGFloat {
        let maxUp = -CGFloat(originalIndex) * itemHeight
        let maxDown = CGFloat(itemCount - 1 - originalIndex) * itemHeight
        return max(maxUp, min(maxDown, vertical))
    }

    init(
        id: ID,
        enableDrag: Bool = true,
        isDragging: Bool,
        itemCount: Int,
        originalIndex: Int,
        itemHeight: CGFloat,
        onDragBegan: @escaping () -> Void,
        onDragChanged: @escaping (CGSize) -> Void,
        onDragEnded: @escaping (CGSize) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.id = id
        self.enableDrag = enableDrag
        self.isDragging = isDragging
        self.itemCount = itemCount
        self.originalIndex = originalIndex
        self.itemHeight = itemHeight
        self.onDragBegan = onDragBegan
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
        self.content = content()
    }

    var body: some View {
        content
            .opacity(isDragging ? 0.9 : 1.0)
            .offset(x: 0, y: isDragging ? dragOffset.height : 0)
            .shadow(
                color: Color.black.opacity(isDragging ? 0.3 : 0),
                radius: isDragging ? 10 : 0,
                x: 0,
                y: isDragging ? 5 : 0
            )
            .zIndex(isDragging ? 10 : 0)
            .coordinateSpace(name: dragSpaceName)
            .onPreferenceChange(DragHandlePreferenceKey.self) { frames in
                dragHandleFrames = frames
            }
            // Handle overlay: long-press on burger then drag. UIKit view so it reliably receives touches (Color.clear often doesn't).
            // Use frozen frame during drag so overlay position doesn't change and cause jitter.
            .overlay(alignment: .topLeading) {
                if enableDrag, let frame = overlayFrameDuringDrag ?? dragHandleFrames.first, frame.width > 0, frame.height > 0 {
                    LongPressDragHandleView(
                        itemHeight: itemHeight,
                        originalIndex: originalIndex,
                        itemCount: itemCount,
                        longPressDuration: longPressDuration,
                        onDragBegan: {
                            shouldHandleDrag = true
                            overlayFrameDuringDrag = dragHandleFrames.first
                            onDragBegan()
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        },
                        onDragChanged: { translation in
                            dragOffset = CGSize(width: 0, height: constrainVerticalOffset(translation))
                            onDragChanged(dragOffset)
                        },
                        onDragEnded: {
                            onDragEnded(dragOffset)
                            overlayFrameDuringDrag = nil
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                dragOffset = .zero
                                shouldHandleDrag = false
                            }
                        }
                    )
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                }
            }
    }
}

// MARK: - UIKit long-press handle (reliably receives touches; Color.clear often doesn't)

private struct LongPressDragHandleView: UIViewRepresentable {
    let itemHeight: CGFloat
    let originalIndex: Int
    let itemCount: Int
    let longPressDuration: Double
    let onDragBegan: () -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            itemHeight: itemHeight,
            originalIndex: originalIndex,
            itemCount: itemCount,
            onDragBegan: onDragBegan,
            onDragChanged: onDragChanged,
            onDragEnded: onDragEnded
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let recognizer = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        recognizer.minimumPressDuration = longPressDuration
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.itemHeight = itemHeight
        context.coordinator.originalIndex = originalIndex
        context.coordinator.itemCount = itemCount
    }

    final class Coordinator: NSObject {
        var itemHeight: CGFloat
        var originalIndex: Int
        var itemCount: Int
        var onDragBegan: () -> Void
        var onDragChanged: (CGFloat) -> Void
        var onDragEnded: () -> Void
        /// Use window coordinates so translation isn't affected by the overlay moving with the dragged content (reduces lag/jitter).
        var initialLocationInWindow: CGPoint = .zero

        init(
            itemHeight: CGFloat,
            originalIndex: Int,
            itemCount: Int,
            onDragBegan: @escaping () -> Void,
            onDragChanged: @escaping (CGFloat) -> Void,
            onDragEnded: @escaping () -> Void
        ) {
            self.itemHeight = itemHeight
            self.originalIndex = originalIndex
            self.itemCount = itemCount
            self.onDragBegan = onDragBegan
            self.onDragChanged = onDragChanged
            self.onDragEnded = onDragEnded
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard let window = recognizer.view?.window else { return }
            let locationInWindow = recognizer.location(in: window)
            switch recognizer.state {
            case .began:
                initialLocationInWindow = locationInWindow
                onDragBegan()
            case .changed:
                let translation = locationInWindow.y - initialLocationInWindow.y
                let maxUp = -CGFloat(originalIndex) * itemHeight
                let maxDown = CGFloat(itemCount - 1 - originalIndex) * itemHeight
                let constrained = max(maxUp, min(maxDown, translation))
                onDragChanged(constrained)
            case .ended, .cancelled:
                onDragEnded()
            default:
                break
            }
        }
    }
}
