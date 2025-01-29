import SwiftUI

struct EmptyStateView: View {
    var onClose: () -> Void

    var body: some View {
        VStack {
            Spacer()

            HStack(alignment: .bottom, spacing: 0) {
                let t = useTranslation(.onboarding)
                DisplayText(t("empty_wallet"))
                    .frame(width: 224)

                Image("empty-state-arrow")
                    .resizable()
                    .scaledToFit()
                    .padding(.leading, 4)
                    .frame(maxHeight: 144)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 130)
            .overlay {
                VStack {
                    Button(action: {
                        Haptics.play(.buttonTap)
                        onClose()
                    }) {
                        Image(systemName: "xmark")
                            .foregroundColor(.textPrimary.opacity(0.8))
                            .frame(width: 44, height: 44, alignment: .topTrailing)
                    }
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
                    Spacer()
                }
            }
        }
    }
}

#Preview {
    EmptyStateView(onClose: {})
        .preferredColorScheme(.dark)
}
