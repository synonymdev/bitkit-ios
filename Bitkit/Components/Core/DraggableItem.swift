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

    /// Minimum drag distance before reordering starts
    private let minDragDistance: CGFloat = 0

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

    /// Track button locations
    @State private var buttonFrames: [CGRect] = []

    /// Track if the gesture started on a button
    @State private var startedOnButton = false

    /// Namespace for coordinate space
    @Namespace private var dragSpace

    /// Track the item's frame
    @State private var itemFrame: CGRect = .zero

    private var windowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .first(where: { $0 is UIWindowScene }) as? UIWindowScene
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
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dragOffset)
            .simultaneousGesture(enableDrag ? dragGesture : nil)
            .shadow(
                color: Color.black.opacity(isDragging ? 0.3 : 0),
                radius: isDragging ? 10 : 0,
                x: 0,
                y: isDragging ? 5 : 0
            )
            .zIndex(isDragging ? 10 : 0)
            .coordinateSpace(name: dragSpace)
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            itemFrame = geometry.frame(in: .named(dragSpace))
                        }
                        .onChange(of: geometry.frame(in: .named(dragSpace))) { newFrame in
                            itemFrame = newFrame
                        }
                }
            )
            .onPreferenceChange(ButtonLocationPreferenceKey.self) { frames in
                buttonFrames = frames
            }
            .detectButton { isButton in
                startedOnButton = isButton
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                let verticalMovement = abs(gesture.translation.height)
                let startLocation = gesture.startLocation

                // Check if we started on a button
                let isOnButton = buttonFrames.contains { frame in
                    // Convert button frame to be relative to the item
                    let relativeFrame = CGRect(
                        x: frame.origin.x - itemFrame.origin.x,
                        y: frame.origin.y - itemFrame.origin.y,
                        width: frame.width,
                        height: frame.height
                    )
                    return relativeFrame.contains(startLocation)
                }

                // Only start dragging if we're not over a button and have enough movement
                if !isDragging && verticalMovement > minDragDistance && !isOnButton {
                    shouldHandleDrag = true
                    onDragBegan()

                    // Give haptic feedback when drag begins
                    let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                    impactFeedback.impactOccurred()
                }

                if isDragging && shouldHandleDrag {
                    // Calculate the maximum allowed offset based on the item's position
                    let maxUpOffset = -CGFloat(originalIndex) * itemHeight
                    let maxDownOffset = CGFloat(itemCount - 1 - originalIndex) * itemHeight

                    // Constrain the vertical movement
                    let proposedOffset = gesture.translation.height
                    let constrainedOffset = max(maxUpOffset, min(maxDownOffset, proposedOffset))

                    dragOffset = CGSize(width: 0, height: constrainedOffset)
                    onDragChanged(dragOffset)
                }
            }
            .onEnded { gesture in
                if isDragging && shouldHandleDrag {
                    let verticalOffset = CGSize(width: 0, height: dragOffset.height)
                    onDragEnded(verticalOffset)
                    dragOffset = .zero
                    shouldHandleDrag = false
                }
            }
    }
}
