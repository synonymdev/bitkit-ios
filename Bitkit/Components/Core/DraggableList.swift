import SwiftUI

/// Helper component that implements reorderable list functionality
struct DraggableList<Data, ID, Content>: View
    where Data: RandomAccessCollection, ID: Hashable, Content: View, Data.Element: Identifiable
{
    /// The data to render in the list
    let data: Data

    /// Flag indicating if drag and drop is enabled
    let enableDrag: Bool

    /// A key path to a property that uniquely identifies each element
    let id: KeyPath<Data.Element, ID>

    /// Height of each item including spacing
    let itemHeight: CGFloat

    /// Callback when items are reordered
    let onReorder: (Int, Int) -> Void

    /// Content view builder for each item
    let content: (Data.Element) -> Content

    /// ID of the currently dragged item
    @State private var draggedItemID: ID?

    /// Track the predicted destination during drag
    @State private var predictedDestinationIndex: Int?

    /// Initialize a reorderable list component
    /// - Parameters:
    ///   - data: The collection of items to display
    ///   - id: Key path to a property that uniquely identifies each element
    ///   - enableDrag: Flag indicating if editing mode is active
    ///   - itemHeight: Height of each item including spacing
    ///   - onReorder: Callback when items are reordered with source and destination indices
    ///   - content: Content view builder for each item
    init(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        enableDrag: Bool = true,
        itemHeight: CGFloat,
        onReorder: @escaping (Int, Int) -> Void,
        @ViewBuilder content: @escaping (Data.Element) -> Content
    ) {
        self.data = data
        self.id = id
        self.enableDrag = enableDrag
        self.itemHeight = itemHeight
        self.onReorder = onReorder
        self.content = content
    }

    var body: some View {
        VStack(spacing: 16) {
            ForEach(Array(data.enumerated()), id: \.element.id) { index, item in
                let itemID = item[keyPath: id]
                let isDraggedItem = draggedItemID == itemID

                DraggableItem(
                    id: itemID,
                    enableDrag: enableDrag,
                    isDragging: isDraggedItem,
                    itemCount: data.count,
                    originalIndex: index,
                    itemHeight: itemHeight,
                    onDragBegan: {
                        if enableDrag {
                            // Only set draggedItemID on long-press; leave predictedDestinationIndex nil until
                            // onDragChanged so no other row gets an offset (fixes "teleport below" on long-press)
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                draggedItemID = itemID
                                predictedDestinationIndex = nil
                            }
                        }
                    },
                    onDragChanged: { amount in
                        guard let draggedID = draggedItemID, let sourceIndex = getIndexForID(draggedID) else { return }
                        let verticalChange = amount.height
                        let moveCount = Int(round(verticalChange / itemHeight))
                        let newDestination = max(0, min(data.count - 1, sourceIndex + moveCount))
                        if newDestination != predictedDestinationIndex {
                            predictedDestinationIndex = newDestination
                            let impactFeedback = UIImpactFeedbackGenerator(style: .soft)
                            impactFeedback.impactOccurred(intensity: 0.7)
                        }
                    },
                    onDragEnded: { _ in
                        guard let draggedID = draggedItemID, let sourceIndex = getIndexForID(draggedID) else { return }

                        // Use the calculated predicted destination as our target
                        let targetIndex = predictedDestinationIndex ?? sourceIndex

                        // Reset drag state first so when the parent re-renders with new order we don't
                        // apply wrong offsets (e.g. "cleared" space at index 0 when dragging index 2)
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            draggedItemID = nil
                            predictedDestinationIndex = nil
                        }

                        if sourceIndex != targetIndex {
                            onReorder(sourceIndex, targetIndex)

                            let notificationFeedback = UINotificationFeedbackGenerator()
                            notificationFeedback.notificationOccurred(.success)
                        }
                    },
                    content: {
                        content(item)
                            .offset(getOffsetForItem(index: index, id: itemID))
                    }
                )
            }
        }
    }

    /// Helper function to get the index for an item ID
    private func getIndexForID(_ id: ID) -> Int? {
        return Array(data.enumerated()).first(where: { $0.element[keyPath: self.id] == id })?.offset
    }

    /// Calculate the offset for each item based on the current drag state
    private func getOffsetForItem(index: Int, id: ID) -> CGSize {
        // Don't offset the dragged item itself - it has its own drag offset
        if id == draggedItemID {
            return .zero
        }

        guard let draggedID = draggedItemID,
              let draggedIndex = getIndexForID(draggedID),
              let predictedIndex = predictedDestinationIndex
        else {
            return .zero
        }

        // Calculate offset for items between source and destination
        if draggedIndex < predictedIndex { // Dragging downward
            if index > draggedIndex && index <= predictedIndex {
                // Move items above the predicted spot upward
                return CGSize(width: 0, height: -itemHeight)
            }
        } else if draggedIndex > predictedIndex { // Dragging upward
            if index < draggedIndex && index >= predictedIndex {
                // Move items below the predicted spot downward
                return CGSize(width: 0, height: itemHeight)
            }
        }

        // No change for other items
        return .zero
    }
}

// Default initializer for DraggableList that uses Element.id
extension DraggableList where ID == Data.Element.ID {
    /// Convenience initializer that uses the element's id property
    /// - Parameters:
    ///   - data: The collection of items to display
    ///   - enableDrag: Flag indicating if editing mode is active
    ///   - itemHeight: Height of each item including spacing
    ///   - onReorder: Callback when items are reordered with source and destination indices
    ///   - content: Content view builder for each item
    init(
        _ data: Data,
        enableDrag: Bool = true,
        itemHeight: CGFloat,
        onReorder: @escaping (Int, Int) -> Void,
        @ViewBuilder content: @escaping (Data.Element) -> Content
    ) {
        self.init(data, id: \.id, enableDrag: enableDrag, itemHeight: itemHeight, onReorder: onReorder, content: content)
    }
}
