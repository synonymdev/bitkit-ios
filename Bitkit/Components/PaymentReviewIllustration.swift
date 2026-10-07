import SwiftUI

struct PaymentReviewIllustration: View {
    var swipeProgress: CGFloat = 0
    var maximumHeight: CGFloat?

    var body: some View {
        Image("coin-stack-4")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxHeight: maximumHeight)
            .frame(width: UIScreen.main.bounds.width * 0.8)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 16)
            .rotationEffect(.degrees(swipeProgress * 14))
    }
}
