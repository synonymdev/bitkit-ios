import SwiftUI

struct FactsWidget: View {
    var isEditing: Bool = false
    var onEditingEnd: (() -> Void)?

    @StateObject private var viewModel = FactsViewModel.shared

    init(
        isEditing: Bool = false,
        onEditingEnd: (() -> Void)? = nil
    ) {
        self.isEditing = isEditing
        self.onEditingEnd = onEditingEnd
    }

    var body: some View {
        BaseWidget(
            type: .facts,
            isEditing: isEditing,
            onEditingEnd: onEditingEnd
        ) {
            FactsWidgetWideContent(fact: viewModel.fact)
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
