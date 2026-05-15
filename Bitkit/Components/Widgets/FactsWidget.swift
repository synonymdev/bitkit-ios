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

struct FactsWidgetWideContent: View {
    let fact: String

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            TitleText(fact)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            BitcoinLogo()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FactsWidgetCompactContent: View {
    let fact: String

    var body: some View {
        BodyMSBText(fact)
            .lineLimit(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .bottomTrailing) {
                BitcoinLogo()
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.gray6)
            .cornerRadius(16)
    }
}

private struct BitcoinLogo: View {
    var body: some View {
        Image("bitcoin")
            .resizable()
            .frame(width: 32, height: 32)
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
