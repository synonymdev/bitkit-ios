import SwiftUI

struct PaymentReviewIllustration: View {
    var swipeProgress: CGFloat = 0
    var maximumHeight: CGFloat?
    var imageSize: CGFloat?
    var isPaymentRequest = false

    var body: some View {
        if isPaymentRequest {
            GeometryReader { geometry in
                let size = min(geometry.size.height, 256) * 9 / 7
                Image("payment-request-coins")
                    .resizable().scaledToFit()
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(swipeProgress * 14))
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .frame(maxHeight: 256)
            .clipped()
        } else {
            Image("coin-stack-4")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: imageSize, height: imageSize)
                .frame(maxHeight: maximumHeight)
                .frame(width: UIScreen.main.bounds.width * 0.8)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 16)
                .rotationEffect(.degrees(swipeProgress * 14))
        }
    }
}
