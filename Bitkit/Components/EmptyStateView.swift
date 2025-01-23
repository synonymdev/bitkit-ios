import SwiftUI

struct EmptyStateView: View {
    var body: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom, spacing: 0) {
                let t = useTranslation(.onboarding)
                let parts = t.parts("empty_wallet")
                (parts.reduce(Text("")) { current, part in
                    current + Text(part.text.uppercased()).foregroundColor(part.isAccent ? .brandAccent : .textPrimary)
                })
                .displayTextStyle()
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