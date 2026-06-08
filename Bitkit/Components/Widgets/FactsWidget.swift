import SwiftUI

struct FactsWidget: View {
    var size: WidgetSize = .wide
    var isEditing: Bool = false
    var onEditingEnd: (() -> Void)?

    @StateObject private var viewModel = FactsViewModel.shared

    init(
        size: WidgetSize = .wide,
        isEditing: Bool = false,
        onEditingEnd: (() -> Void)? = nil
    ) {
        self.size = size
        self.isEditing = isEditing
        self.onEditingEnd = onEditingEnd
    }

    var body: some View {
        BaseWidget(
            type: .facts,
            size: size,
            isEditing: isEditing,
            onEditingEnd: onEditingEnd
        ) {
            if size == .small {
                FactsWidgetCompactContent(fact: viewModel.fact)
            } else {
                FactsWidgetWideContent(fact: viewModel.fact)
            }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        FactsWidget()
        FactsWidget(isEditing: true)
    }
    .padding()
    .background(Color.black)
    .environmentObject(WalletViewModel())
    .preferredColorScheme(.dark)
}
