import SwiftUI

/// Helper component that implements reorderable list functionality
struct DraggableList<Data, ID, Content>: View
where Data: RandomAccessCollection, ID: Hashable, Content: View, Data.Element: Identifiable {
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
    @State private var draggedItemID: ID? = nil

    /// Current drag amount of the dragged item
    @State private var dragAmount = CGSize.zero

    /// Track the predicted destination during drag
    @State private var predictedDestinationIndex: Int? = nil

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
                            // Start dragging with animation
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                draggedItemID = itemID
                                // Initially, the item is at its original position
                                predictedDestinationIndex = index
                            }
                        }
                    },
                    onDragChanged: { amount in
                        dragAmount = amount

                        // Only calculate predicted position if we have a dragged item
                        if draggedItemID != nil, let sourceIndex = getIndexForID(draggedItemID!) {
                            // Calculate how many positions to move based on vertical translation
                            let verticalChange = amount.height
                            let moveCount = Int(round(verticalChange / itemHeight))

                            // Calculate predicted destination with bounds checking
                            let newDestination = max(0, min(data.count - 1, sourceIndex + moveCount))

                            // Only update if the predicted destination changed
                            if newDestination != predictedDestinationIndex {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                                    predictedDestinationIndex = newDestination
                                }

                                // Very light impact feedback when crossing item boundaries
                                let impactFeedback = UIImpactFeedbackGenerator(style: .soft)
                                impactFeedback.impactOccurred(intensity: 0.7)
                            }
                        }
                    },
                    onDragEnded: { finalAmount in
                        if draggedItemID == nil { return }

                        // Find the source index for the dragged item
                        guard let sourceIndex = getIndexForID(draggedItemID!) else { return }

                        // Use the calculated predicted destination as our target
                        let targetIndex = predictedDestinationIndex ?? sourceIndex

                        // Call the reorder handler if the position changed
                        if sourceIndex != targetIndex {
                            onReorder(sourceIndex, targetIndex)

                            // Success haptic feedback
                            let notificationFeedback = UINotificationFeedbackGenerator()
                            notificationFeedback.notificationOccurred(.success)
                        }

                        // Reset drag state with smooth animation
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            draggedItemID = nil
                            dragAmount = .zero
                            predictedDestinationIndex = nil
                        }
                    },
                    content: {
                        content(item)
                            .offset(getOffsetForItem(index: index, id: itemID))
                            .animation(.spring(response: 0.45, dampingFraction: 0.9), value: predictedDestinationIndex)
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

        // If we're not dragging or don't have a predicted destination, no offset
        guard let draggedIndex = getIndexForID(draggedItemID ?? id),
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

struct PreviewItem: Identifiable {
    let id = UUID()
    let name: String
}

struct PreviewItemView: View {
    let item: PreviewItem

    var body: some View {
        Text(item.name)
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background(Color.blue.opacity(0.3))
            .cornerRadius(8)
            .padding(.horizontal)
    }
}

struct DraggableListPreview: View {
    @State private var items = [
        PreviewItem(name: "Item 1"),
        PreviewItem(name: "Item 2"),
        PreviewItem(name: "Item 3"),
        PreviewItem(name: "Item 4"),
        PreviewItem(name: "Item 5"),
    ]

    var body: some View {
        ScrollView {
            DraggableList(
                items,
                enableDrag: true,
                itemHeight: 76, // 60 for content + 16 for spacing
                onReorder: { sourceIndex, destinationIndex in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        let item = items.remove(at: sourceIndex)
                        items.insert(item, at: destinationIndex)
                    }
                }
            ) { item in
                PreviewItemView(item: item)
            }
            .padding(.vertical)
        }
    }
}

#Preview("DraggableList") {
    DraggableListPreview()
}
