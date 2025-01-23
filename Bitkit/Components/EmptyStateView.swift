import SwiftUI

struct EmptyStateView: View {
    var body: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom, spacing: 0) {
                let t = useTranslation(.onboarding)
                DisplayText(text: t("empty_wallet"))
                    .frame(maxWidth: UIScreen.main.bounds.width / 2)

                Image("empty-state-arrow")
                    .resizable()
                    .scaledToFit()
                    .padding(.leading, 4)
                    .frame(maxWidth: UIScreen.main.bounds.width / 2, maxHeight: 144, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 130)
        }
    }
}

#Preview {
    EmptyStateView()
        .preferredColorScheme(.dark)
}
