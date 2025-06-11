import SwiftUI

// UIKit Scroll View for better snapping behavior
struct SnapCarousel<Item: Identifiable, Content: View>: UIViewRepresentable {
    var items: [Item]
    var itemSize: CGFloat
    var itemSpacing: CGFloat
    var onItemTap: (Item) -> Void
    var content: (Item) -> Content

    init(
        items: [Item],
        itemSize: CGFloat,
        itemSpacing: CGFloat,
        onItemTap: @escaping (Item) -> Void,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.items = items
        self.itemSize = itemSize
        self.itemSpacing = itemSpacing
        self.onItemTap = onItemTap
        self.content = content
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delegate = context.coordinator
        scrollView.decelerationRate = .fast

        // Add items to scrollView
        let stackView = UIStackView()
        stackView.axis = .horizontal
        stackView.spacing = itemSpacing
        stackView.alignment = .center
        stackView.isUserInteractionEnabled = true

        // Add padding at beginning
        stackView.addArrangedSubview(UIView())
        stackView.arrangedSubviews.first?.widthAnchor.constraint(equalToConstant: 0).isActive = true

        // Add each item
        for (index, item) in items.enumerated() {
            let hostingController = UIHostingController(
                rootView: content(item)
                    .frame(width: itemSize, height: itemSize)
            )

            hostingController.view.backgroundColor = .clear
            let itemView = hostingController.view!
            itemView.tag = index

            // Add tap gesture for the item
            let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.itemTapped(_:)))
            itemView.addGestureRecognizer(tapGesture)

            stackView.addArrangedSubview(itemView)

            // Set size constraints
            itemView.widthAnchor.constraint(equalToConstant: itemSize).isActive = true
            itemView.heightAnchor.constraint(equalToConstant: itemSize).isActive = true
        }

        // Add padding at end
        stackView.addArrangedSubview(UIView())
        stackView.arrangedSubviews.last?.widthAnchor.constraint(equalToConstant: itemSpacing).isActive = true

        scrollView.addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        // Updates happen via the coordinator
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        let parent: SnapCarousel

        init(_ parent: SnapCarousel) {
            self.parent = parent
        }

        @objc func itemTapped(_ sender: UITapGestureRecognizer) {
            if let itemView = sender.view, let stackView = itemView.superview as? UIStackView {
                // Find the index in the stack view (accounting for the padding view at index 0)
                if let index = stackView.arrangedSubviews.firstIndex(of: itemView), index > 0, index - 1 < parent.items.count {
                    parent.onItemTap(parent.items[index - 1])
                }
            }
        }

        // Snap to the nearest item when scrolling ends
        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>)
        {
            let itemWidthWithSpacing = parent.itemSize + parent.itemSpacing

            // Calculate position
            let targetX = scrollView.contentOffset.x + velocity.x * 60.0 // Add momentum

            // Calculate the nearest item index
            let index = round(targetX / itemWidthWithSpacing)

            // Calculate the snap position
            let snapPosition = max(0, index * itemWidthWithSpacing)

            // Set the target offset
            targetContentOffset.pointee = CGPoint(x: snapPosition, y: 0)
        }
    }
}
